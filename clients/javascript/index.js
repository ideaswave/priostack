'use strict';

/**
 * Official Node.js client for the Priostack Agent Context Network (ACN).
 *
 * The ACN is a Model Context Protocol (MCP) server reached over JSON-RPC 2.0.
 * An agent self-registers, opens a session with the returned bearer token,
 * creates isolated context spaces, stores typed facts, reads them back, and
 * shares them with other agents through scoped capability grants.
 *
 * This client speaks the exact wire contract of the live server: it unwraps the
 * MCP `result.content[0].text` envelope, throws typed errors on tool-level
 * denials, reuses the global keep-alive HTTP pool, retries transient network
 * faults with backoff (but never a request that may have already been applied),
 * and captures the session id automatically on {@link ACNClient#connect}.
 *
 * Quickstart:
 *
 *     const { ACNClient } = require('@priostack/acn');
 *
 *     const acn = new ACNClient();
 *     await acn.register('my-agent');            // token captured internally
 *     await acn.connect();                        // session id captured internally
 *     const space = await acn.createSpace('prod-memory');
 *     await acn.store(space.spaceId, [
 *       { content: 'Refunds over $500 need manager approval.', type: 'declaration' },
 *     ]);
 *     const hits = await acn.fetch(space.spaceId, { query: 'refund' });
 *     for (const line of hits.contents()) console.log(line);
 *     await acn.close();
 */

const {
  ACNTransportError,
  toolErrorFor,
  ...errorExports
} = require('./errors');
const { version: VERSION } = require('./package.json');

/** Canonical MCP endpoint (Streamable HTTP). `/acn/rpc` is a working alias. */
const DEFAULT_ENDPOINT = 'https://priostack.com/mcp';

/**
 * Object `type` values the `store` tool accepts. Anything else is rejected
 * server-side with `invalid-query` (proposals/inferences go through the
 * propose/commit path, not `store`).
 */
const STORE_KINDS = Object.freeze(['declaration', 'observation', 'measurement']);

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// --------------------------------------------------------------------------- //
// Typed result objects
//
// The server returns plain JSON. These lightweight classes give ergonomic
// access to the common calls (camelCase everywhere for JS callers) while still
// exposing the full raw `data` object via `.raw` for anything not surfaced.
// --------------------------------------------------------------------------- //

/** Result of {@link ACNClient#register}. */
class RegisterResult {
  constructor(data) {
    this.token = data.token || '';
    this.agentId = data.agentId || '';
    this.accountId = data.accountId || '';
    this.tier = data.tier || '';
    this.raw = data;
  }
}

/** Result of {@link ACNClient#connect}. Note the server uses PascalCase keys. */
class ConnectResult {
  constructor(data) {
    this.sessionId = data.SessionID || '';
    this.resolvedAccount = data.ResolvedAccount || '';
    this.grantedCapabilities = data.GrantedCapabilities || [];
    this.grantedContextRights = data.GrantedContextRights || [];
    this.boundSpace = data.BoundSpace || '';
    this.resolvedMaxTokens = data.ResolvedMaxTokens || 0;
    this.raw = data;
  }
}

/** Result of {@link ACNClient#createSpace}. */
class SpaceResult {
  constructor(data) {
    if (typeof data.spaceId !== 'string' || !data.spaceId) {
      throw new ACNTransportError(
        `create_space returned no spaceId: ${JSON.stringify(data)}`,
        { method: 'noetic.create_space' }
      );
    }
    this.spaceId = data.spaceId;
    this.accountId = data.accountId || '';
    this.persistenceMode = data.persistenceMode || '';
    this.protectionLevel = data.protectionLevel || '';
    this.raw = data;
  }
}

/** Result of {@link ACNClient#store}. */
class StoreResult {
  constructor(data) {
    this.objectRefs = data.objectRefs || [];
    this.raw = data;
  }

  /** How many objects were ingested. */
  get count() {
    return this.objectRefs.length;
  }
}

/** Result of {@link ACNClient#fetch}. */
class FetchResult {
  constructor(data, fallbackSpace) {
    this.space = data.space || fallbackSpace;
    this.objects = data.objects || [];
    this.matched = data.matched || 0;
    this.total = data.total || 0;
    this.returnedTokens = data.returnedTokens || 0;
    this.raw = data;
  }

  /** Just the `content` strings of the returned objects. */
  contents() {
    return this.objects.map((o) => (o && o.content) || '');
  }
}

/** Result of {@link ACNClient#grantAccess} / {@link ACNClient#approveRequest}. */
class GrantResult {
  constructor(data) {
    this.capabilityRef = data.capabilityRef || '';
    this.subject = data.subject || '';
    this.resource = data.resource || '';
    this.effectiveRights = data.effectiveRights || [];
    this.raw = data;
  }
}

function normalizeObject(obj) {
  if (obj === null || typeof obj !== 'object') {
    throw new TypeError('each stored object must be an object with a "content" field');
  }
  if (!('content' in obj)) {
    throw new Error("each stored object needs a 'content' field");
  }
  const kind = obj.type || 'declaration';
  if (!STORE_KINDS.includes(kind)) {
    throw new Error(
      `invalid object type ${JSON.stringify(kind)}; must be one of ${STORE_KINDS.join(', ')}`
    );
  }
  const out = { content: obj.content, type: kind };
  if (obj.provenance) {
    out.provenance = Array.from(obj.provenance);
  }
  return out;
}

/**
 * A sturdy JSON-RPC client for the Priostack ACN.
 *
 * @param {object} [options]
 * @param {string} [options.endpoint] Base RPC URL. Defaults to the canonical
 *   Streamable-HTTP MCP endpoint. The legacy `.../acn/rpc` path is an alias.
 * @param {string|null} [options.token] A previously issued bearer token, to
 *   reconnect an existing agent without registering again. `register()` sets it.
 * @param {number} [options.timeout] Per-request timeout in seconds (default 30).
 * @param {number} [options.maxRetries] How many times to retry *transport*
 *   faults. Only pre-response connection errors and back-pressure statuses
 *   (429, 503) are retried; timeouts are **not** retried, so a non-idempotent
 *   call such as `store` is never silently duplicated.
 * @param {number} [options.backoffFactor] Exponential backoff base (seconds).
 */
class ACNClient {
  constructor({
    endpoint = DEFAULT_ENDPOINT,
    token = null,
    timeout = 30,
    maxRetries = 3,
    backoffFactor = 0.5,
  } = {}) {
    this.endpoint = endpoint;
    this.timeoutMs = Math.round(timeout * 1000);
    this.token = token;
    this.sessionId = null;
    this.maxRetries = maxRetries;
    this.backoffFactor = backoffFactor;

    this._nextId = 1;
    this._headers = {
      'Content-Type': 'application/json',
      // Ask for a plain JSON reply; the Streamable-HTTP endpoint would
      // otherwise be free to answer a POST as a one-shot SSE frame.
      Accept: 'application/json',
      'User-Agent': `priostack-node/${VERSION}`,
    };
  }

  /** Whether a session id has been captured. */
  get connected() {
    return this.sessionId !== null;
  }

  /** Best-effort disconnect (if connected). Never throws. */
  async close() {
    try {
      if (this.sessionId) {
        await this.disconnect();
      }
    } catch (_err) {
      // closing must never raise
    }
  }

  // -- transport ----------------------------------------------------------- //

  async _post(payload, method) {
    let attempt = 0;
    for (;;) {
      let resp;
      let bodyText;
      try {
        resp = await globalThis.fetch(this.endpoint, {
          method: 'POST',
          headers: this._headers,
          body: JSON.stringify(payload),
          signal: AbortSignal.timeout(this.timeoutMs),
        });
        bodyText = await resp.text();
      } catch (err) {
        // A timeout may have reached the server; do not retry it. A raw
        // connection error (DNS/refused/reset) never reached it — safe to retry.
        const isTimeout =
          err && (err.name === 'TimeoutError' || err.name === 'AbortError');
        if (!isTimeout && attempt < this.maxRetries) {
          await sleep(this._backoffMs(attempt));
          attempt += 1;
          continue;
        }
        throw new ACNTransportError(
          `network error calling ${method}: ${(err && err.message) || err}`,
          { method }
        );
      }

      if (resp.status >= 400) {
        if ((resp.status === 429 || resp.status === 503) && attempt < this.maxRetries) {
          await sleep(this._backoffMs(attempt));
          attempt += 1;
          continue;
        }
        throw new ACNTransportError(
          `HTTP ${resp.status} calling ${method}: ${bodyText.slice(0, 500)}`,
          { method, httpStatus: resp.status }
        );
      }
      return bodyText;
    }
  }

  _backoffMs(attempt) {
    // 0s before the first retry, then exponential (matches urllib3 semantics).
    return attempt === 0 ? 0 : this.backoffFactor * 2 ** (attempt - 1) * 1000;
  }

  /**
   * Invoke any `noetic.*` tool and return its unwrapped `data` object.
   *
   * This is the low-level escape hatch behind every typed method — use it to
   * reach tools this client does not wrap explicitly (there are ~40). It
   * performs the full round trip: builds the JSON-RPC `tools/call` envelope,
   * unwraps `result.content[0].text`, and throws an {@link ACNToolError}
   * subclass when the tool returns `ok: false`.
   *
   * @param {string} method
   * @param {object} [args]
   * @returns {Promise<object>}
   */
  async call(method, args = {}) {
    const payload = {
      jsonrpc: '2.0',
      id: this._nextId++,
      method: 'tools/call',
      params: { name: method, arguments: args },
    };

    const bodyText = await this._post(payload, method);

    let body;
    try {
      body = JSON.parse(bodyText);
    } catch (_err) {
      throw new ACNTransportError(
        `non-JSON response calling ${method}: ${bodyText.slice(0, 500)}`,
        { method }
      );
    }

    // JSON-RPC protocol error (unknown method, bad params) — no result.
    if (body && typeof body === 'object' && body.error) {
      const err = body.error;
      throw new ACNTransportError(
        `JSON-RPC error calling ${method}: ${err.message || JSON.stringify(err)}`,
        { method, code: err.code }
      );
    }

    const result = body && typeof body === 'object' ? body.result : null;
    if (!result || typeof result !== 'object') {
      throw new ACNTransportError(
        `malformed response calling ${method}: ${bodyText.slice(0, 500)}`,
        { method }
      );
    }

    const envelope = ACNClient._unwrap(result, method);

    if (!envelope.ok) {
      throw toolErrorFor(envelope.outcome || '', envelope.detail || '', {
        method,
        data: envelope.data,
      });
    }

    // `data` is optional (some tools return ok with no payload).
    const data = envelope.data;
    return data && typeof data === 'object' && !Array.isArray(data) ? data : { data };
  }

  /** Parse the MCP `content[0].text` JSON envelope out of a result. */
  static _unwrap(result, method) {
    const content = result.content;
    if (!Array.isArray(content) || content.length === 0) {
      throw new ACNTransportError(`response for ${method} had no content block`, { method });
    }
    const first = content[0];
    const text = first && typeof first === 'object' ? first.text : undefined;
    if (typeof text !== 'string') {
      throw new ACNTransportError(`response for ${method} had no text payload`, { method });
    }
    let envelope;
    try {
      envelope = JSON.parse(text);
    } catch (_err) {
      throw new ACNTransportError(
        `could not decode envelope for ${method}: ${text.slice(0, 300)}`,
        { method }
      );
    }
    if (!envelope || typeof envelope !== 'object' || Array.isArray(envelope)) {
      throw new ACNTransportError(`envelope for ${method} was not an object`, { method });
    }
    return envelope;
  }

  _requireSession() {
    if (!this.sessionId) {
      throw new ACNTransportError('no active session: call connect() first');
    }
    return this.sessionId;
  }

  // -- identity ------------------------------------------------------------ //

  /**
   * Self-register a new agent and capture its bearer token.
   *
   * Only available on the online multi-agent ACN. The token is shown once; it
   * is stored on this client (`this.token`) and returned so you can persist it
   * for future sessions. Throws `NotSupportedError` on a single-tenant ACN.
   *
   * @param {string} [displayName]
   * @returns {Promise<RegisterResult>}
   */
  async register(displayName = 'agent') {
    const data = await this.call('noetic.register', { displayName });
    this.token = data.token;
    return new RegisterResult(data);
  }

  /**
   * Open a session with a bearer token and capture the session id.
   *
   * Pass `token` explicitly, or rely on the token captured by `register()` /
   * passed to the constructor. Re-call `connect` after being granted access to
   * a space so the widened scope is applied.
   *
   * @param {string|null} [token]
   * @param {{maxTokens?: number}} [options]
   * @returns {Promise<ConnectResult>}
   */
  async connect(token = null, { maxTokens = 4096 } = {}) {
    const tok = token || this.token;
    if (!tok) {
      throw new ACNTransportError('connect() needs a token: register() first or pass a token');
    }
    const data = await this.call('noetic.connect', {
      token: tok,
      maxResponseTokens: maxTokens,
    });
    // The server serializes ConnectResult with Go field names (PascalCase).
    this.sessionId = data.SessionID || null;
    this.token = tok;
    if (!this.sessionId) {
      throw new ACNTransportError(`connect returned no SessionID: ${JSON.stringify(data)}`, {
        method: 'noetic.connect',
      });
    }
    return new ConnectResult(data);
  }

  /** End the current session. Durable facts are **not** revoked. */
  async disconnect() {
    const sid = this._requireSession();
    const data = await this.call('noetic.disconnect', { sessionId: sid });
    this.sessionId = null;
    return data;
  }

  /**
   * Mint a fresh bearer token for this agent and retire the old one.
   *
   * Existing sessions keep working; use the new token for future `connect`
   * calls. The new token is stored on this client and returned.
   *
   * @returns {Promise<string>}
   */
  async rotateToken() {
    const sid = this._requireSession();
    const data = await this.call('noetic.rotate_token', { sessionId: sid });
    this.token = data.token;
    return data.token;
  }

  /** Discover the grantable rights + world-mutation vocabulary in scope. */
  async capabilities() {
    const sid = this._requireSession();
    return this.call('noetic.capabilities', { sessionId: sid });
  }

  // -- spaces + facts ------------------------------------------------------ //

  /**
   * Create an isolated context space and return its resolved id.
   *
   * `defaultRights` is the ceiling of rights the space may offer to others; it
   * does not grant anything by itself.
   *
   * @param {string} displayName
   * @param {{defaultRights?: string[], visibility?: string, persistenceMode?: string, protectionLevel?: string}} [options]
   * @returns {Promise<SpaceResult>}
   */
  async createSpace(
    displayName,
    { defaultRights, visibility, persistenceMode, protectionLevel } = {}
  ) {
    const sid = this._requireSession();
    const args = { sessionId: sid, displayName };
    if (defaultRights != null) args.defaultRights = Array.from(defaultRights);
    if (visibility != null) args.visibility = visibility;
    if (persistenceMode != null) args.persistenceMode = persistenceMode;
    if (protectionLevel != null) args.protectionLevel = protectionLevel;
    const data = await this.call('noetic.create_space', args);
    return new SpaceResult(data);
  }

  /**
   * Persist typed facts into a space.
   *
   * Each object is `{ content: string, type: <kind>, provenance?: [...] }`
   * where `type` is one of {@link STORE_KINDS}
   * (`declaration`/`observation`/`measurement`). Writing needs the write right
   * and the `mutate` capability; the space owner has both. The `space` argument
   * carries the space id.
   *
   * @param {string} spaceId
   * @param {Array<{content: string, type?: string, provenance?: any[]}>} objects
   * @returns {Promise<StoreResult>}
   */
  async store(spaceId, objects) {
    const sid = this._requireSession();
    const objs = Array.from(objects, normalizeObject);
    const data = await this.call('noetic.store', {
      sessionId: sid,
      space: spaceId,
      objects: objs,
    });
    return new StoreResult(data);
  }

  /**
   * Read stored objects back from a space (this is the content reader).
   *
   * `query` is a case-insensitive **substring** filter over content (not
   * semantic search); `limit` caps the count (0 = server default). Distinct
   * from `noetic.query`, which is a geometric divergence probe. The `space`
   * argument carries the space id.
   *
   * @param {string} spaceId
   * @param {{query?: string, limit?: number}} [options]
   * @returns {Promise<FetchResult>}
   */
  async fetch(spaceId, { query = '', limit = 0 } = {}) {
    const sid = this._requireSession();
    const args = { sessionId: sid, space: spaceId };
    if (query) args.query = query;
    if (limit) args.limit = limit;
    const data = await this.call('noetic.fetch', args);
    return new FetchResult(data, spaceId);
  }

  // -- sharing ------------------------------------------------------------- //

  /**
   * Grant another agent scoped access to a space you own.
   *
   * `rights` are content rights (`read`/`write`/`quote`/`share`/`export`/...).
   * `worldMutation` is the separate mutation ladder (`read`/`propose`/`mutate`);
   * leave it undefined and the server derives it from the rights (granting
   * `write` confers `mutate`). `subjectPrincipal` is the grantee's agentId.
   *
   * @param {string} spaceId
   * @param {string} subjectPrincipal
   * @param {{rights?: string[], worldMutation?: string, persistenceMode?: string}} [options]
   * @returns {Promise<GrantResult>}
   */
  async grantAccess(
    spaceId,
    subjectPrincipal,
    { rights = ['read', 'quote'], worldMutation, persistenceMode } = {}
  ) {
    const sid = this._requireSession();
    // The server names the space argument `resource`. `space` is sent too as a
    // harmless alias for older builds; unknown fields are ignored.
    const args = {
      sessionId: sid,
      subjectPrincipal,
      resource: spaceId,
      space: spaceId,
      rights: Array.from(rights),
    };
    if (worldMutation != null) args.worldMutation = worldMutation;
    if (persistenceMode != null) args.persistenceMode = persistenceMode;
    const data = await this.call('noetic.grant', args);
    return new GrantResult(data);
  }

  /** Revoke a previously granted capability (immediate, forward-only). */
  async revokeAccess(capabilityRef) {
    const sid = this._requireSession();
    return this.call('noetic.revoke', { sessionId: sid, capabilityRef });
  }

  /**
   * Ask the owner of a remote space for scoped access (consumer side).
   *
   * The rights argument is named `rights` (not `requestedRights`); the `space`
   * argument carries the space id.
   *
   * @param {string} spaceId
   * @param {string[]} rights
   * @param {{persistenceMode?: string, reason?: string}} [options]
   * @returns {Promise<object>}
   */
  async requestAccess(spaceId, rights, { persistenceMode, reason = '' } = {}) {
    const sid = this._requireSession();
    const args = {
      sessionId: sid,
      space: spaceId,
      rights: Array.from(rights),
    };
    if (persistenceMode != null) args.persistenceMode = persistenceMode;
    if (reason) args.reason = reason;
    return this.call('noetic.request_access', args);
  }

  /** List pending access requests on spaces you own (owner side). */
  async listRequests() {
    const sid = this._requireSession();
    const data = await this.call('noetic.list_requests', { sessionId: sid });
    return data.requests || [];
  }

  /**
   * Approve a pending access request, minting the grant (owner side).
   *
   * @param {string} requestId
   * @param {{rights?: string[], worldMutation?: string, persistenceMode?: string}} [options]
   * @returns {Promise<GrantResult>}
   */
  async approveRequest(requestId, { rights, worldMutation, persistenceMode } = {}) {
    const sid = this._requireSession();
    const args = { sessionId: sid, requestId };
    if (rights != null) args.rights = Array.from(rights);
    if (worldMutation != null) args.worldMutation = worldMutation;
    if (persistenceMode != null) args.persistenceMode = persistenceMode;
    const data = await this.call('noetic.approve_request', args);
    return new GrantResult(data);
  }

  /** Deny a pending access request (owner side). */
  async denyRequest(requestId) {
    const sid = this._requireSession();
    return this.call('noetic.deny_request', { sessionId: sid, requestId });
  }

  // -- discovery + introspection ------------------------------------------ //

  /**
   * List publicly discoverable spaces (no session required).
   *
   * @param {string} [query]
   * @param {{limit?: number}} [options]
   * @returns {Promise<object[]>}
   */
  async discover(query = '', { limit = 0 } = {}) {
    const args = {};
    if (query) args.query = query;
    if (limit) args.limit = limit;
    const data = await this.call('noetic.discover', args);
    return data.spaces || [];
  }

  /** Set a space's discovery visibility. */
  async publish(spaceId, { visibility = 'public' } = {}) {
    const sid = this._requireSession();
    return this.call('noetic.publish', { sessionId: sid, space: spaceId, visibility });
  }

  /** Return scope/account/space usage metrics for the session. */
  async metrics() {
    const sid = this._requireSession();
    return this.call('noetic.metrics', { sessionId: sid });
  }
}

module.exports = {
  ACNClient,
  DEFAULT_ENDPOINT,
  STORE_KINDS,
  VERSION,
  RegisterResult,
  ConnectResult,
  SpaceResult,
  StoreResult,
  FetchResult,
  GrantResult,
  ...errorExports,
  ACNTransportError,
  toolErrorFor,
};
