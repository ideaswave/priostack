/**
 * Official TypeScript client for the Priostack Agent Context Network (ACN).
 *
 * The ACN is a Model Context Protocol (MCP) server reached over JSON-RPC 2.0.
 * An agent self-registers, opens a session with the returned bearer token,
 * creates isolated context spaces, stores typed facts, reads them back, and
 * shares them with other agents through scoped capability grants.
 *
 * This client speaks the exact wire contract of the live server: it unwraps the
 * MCP `result.content[0].text` envelope, throws typed errors on tool-level
 * denials, reuses one `fetch` implementation with a bounded timeout, and
 * captures the session id automatically on {@link ACNClient.connect}.
 *
 * @example
 * ```ts
 * import { ACNClient } from "@priostack/acn";
 *
 * const acn = new ACNClient();
 * await acn.register("my-agent");            // token captured internally
 * await acn.connect();                       // session id captured internally
 * const space = await acn.createSpace("prod-memory");
 * await acn.store(space.spaceId, [
 *   { content: "Refunds over $500 need manager approval.", type: "declaration" },
 * ]);
 * const hits = await acn.fetch(space.spaceId, { query: "refund" });
 * for (const line of hits.contents) console.log(line);
 * ```
 */

import {
  ACNTransportError,
  toolErrorFor,
} from "./exceptions.js";
import {
  STORE_KINDS,
  type AcnRecord,
  type ACNClientOptions,
  type ApproveRequestOptions,
  type ConnectOptions,
  type ConnectResult,
  type CreateSpaceOptions,
  type DiscoverOptions,
  type Envelope,
  type FetchOptions,
  type FetchResult,
  type FetchedObject,
  type GrantOptions,
  type GrantResult,
  type RegisterResult,
  type RequestAccessOptions,
  type SpaceResult,
  type StoreResult,
  type StoredObject,
} from "./types.js";

/** Canonical MCP endpoint (Streamable HTTP). `/acn/rpc` is a working alias. */
export const DEFAULT_ENDPOINT = "https://priostack.com/mcp";

/** Client version, reported in the `User-Agent` header. */
export const VERSION = "0.3.0";

// --------------------------------------------------------------------------- //
// Small internal helpers for narrowing the untyped server JSON.
// --------------------------------------------------------------------------- //
function isRecord(value: unknown): value is AcnRecord {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function asString(value: unknown): string {
  return typeof value === "string" ? value : "";
}

function asNumber(value: unknown): number {
  return typeof value === "number" ? value : 0;
}

function asStringArray(value: unknown): string[] {
  return Array.isArray(value) ? value.filter((v): v is string => typeof v === "string") : [];
}

function errorMessage(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}

function normalizeObject(obj: StoredObject): AcnRecord {
  if (obj == null || typeof obj.content !== "string") {
    throw new TypeError("each stored object needs a 'content' string field");
  }
  const kind = obj.type ?? "declaration";
  if (!STORE_KINDS.includes(kind)) {
    throw new TypeError(
      `invalid object type ${JSON.stringify(kind)}; must be one of ${STORE_KINDS.join(", ")}`,
    );
  }
  const out: AcnRecord = { content: obj.content, type: kind };
  if (obj.provenance && obj.provenance.length > 0) {
    out.provenance = [...obj.provenance];
  }
  return out;
}

function toGrantResult(data: AcnRecord): GrantResult {
  return {
    capabilityRef: asString(data.capabilityRef),
    subject: asString(data.subject),
    resource: asString(data.resource),
    effectiveRights: asStringArray(data.effectiveRights),
    raw: data,
  };
}

/**
 * A sturdy JSON-RPC client for the Priostack ACN.
 *
 * A single instance reuses one `fetch` implementation and an incrementing
 * JSON-RPC id across all calls. It is safe to keep one client for the lifetime
 * of an agent.
 */
export class ACNClient {
  /** Base RPC URL this client posts to. */
  readonly endpoint: string;

  /** The current bearer token, if one has been captured or supplied. */
  token?: string;

  /** The current session id, captured by {@link ACNClient.connect}. */
  sessionId?: string;

  private readonly timeoutMs: number;
  private readonly fetchImpl: typeof fetch | undefined;
  private readonly headers: Record<string, string>;
  private nextId = 1;

  constructor(options: ACNClientOptions = {}) {
    this.endpoint = options.endpoint ?? DEFAULT_ENDPOINT;
    this.token = options.token;
    this.timeoutMs = options.timeoutMs ?? 30_000;
    this.headers = { ...(options.headers ?? {}) };
    const globalFetch = typeof globalThis.fetch === "function" ? globalThis.fetch : undefined;
    // Bind to globalThis so browser fetch is not invoked with the wrong `this`.
    this.fetchImpl = options.fetch ?? (globalFetch ? globalFetch.bind(globalThis) : undefined);
  }

  /** Whether a session id has been captured. */
  get connected(): boolean {
    return this.sessionId != null;
  }

  // -- transport ----------------------------------------------------------- //

  /**
   * Invoke any `noetic.*` tool and return its unwrapped `data` object.
   *
   * This is the low-level escape hatch behind every typed method — use it to
   * reach tools this client does not wrap explicitly (there are ~40). It
   * performs the full round trip: builds the JSON-RPC `tools/call` envelope,
   * unwraps `result.content[0].text`, and throws an {@link ACNToolError}
   * subclass when the tool returns `ok: false`, or an {@link ACNTransportError}
   * on any transport/protocol failure.
   */
  async call(method: string, args: AcnRecord): Promise<AcnRecord> {
    if (!this.fetchImpl) {
      throw new ACNTransportError(
        "no fetch implementation available; pass { fetch } to the constructor",
        { method },
      );
    }

    const payload = {
      jsonrpc: "2.0",
      id: this.nextId++,
      method: "tools/call",
      params: { name: method, arguments: args },
    };

    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), this.timeoutMs);
    try {
      let resp: Response;
      try {
        resp = await this.fetchImpl(this.endpoint, {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            // Ask for a plain JSON reply; the Streamable-HTTP endpoint would
            // otherwise be free to answer a POST as a one-shot SSE frame.
            Accept: "application/json",
            "User-Agent": `priostack-typescript/${VERSION}`,
            ...this.headers,
          },
          body: JSON.stringify(payload),
          signal: controller.signal,
        });
      } catch (err) {
        throw new ACNTransportError(`network error calling ${method}: ${errorMessage(err)}`, {
          method,
        });
      }

      if (!resp.ok) {
        const text = await this.readBody(resp, method);
        throw new ACNTransportError(
          `HTTP ${resp.status} calling ${method}: ${text.slice(0, 500)}`,
          { method, httpStatus: resp.status },
        );
      }

      const raw = await this.readBody(resp, method);
      let body: unknown;
      try {
        body = JSON.parse(raw);
      } catch {
        throw new ACNTransportError(
          `non-JSON response calling ${method}: ${raw.slice(0, 500)}`,
          { method },
        );
      }

      // JSON-RPC protocol error (unknown method, bad params) — no result.
      if (isRecord(body) && body.error != null) {
        const err = isRecord(body.error) ? body.error : {};
        const code = typeof err.code === "number" ? err.code : undefined;
        const message = typeof err.message === "string" ? err.message : JSON.stringify(err);
        throw new ACNTransportError(`JSON-RPC error calling ${method}: ${message}`, {
          method,
          code,
        });
      }

      const result = isRecord(body) ? body.result : undefined;
      if (!isRecord(result)) {
        throw new ACNTransportError(
          `malformed response calling ${method}: ${raw.slice(0, 500)}`,
          { method },
        );
      }

      const envelope = this.unwrap(result, method);
      if (envelope.ok !== true) {
        throw toolErrorFor(envelope.outcome ?? "", envelope.detail ?? "", {
          method,
          data: envelope.data,
        });
      }

      // `data` is optional (some tools return ok with no payload).
      return isRecord(envelope.data) ? envelope.data : { data: envelope.data };
    } finally {
      clearTimeout(timer);
    }
  }

  private async readBody(resp: Response, method: string): Promise<string> {
    try {
      return await resp.text();
    } catch (err) {
      throw new ACNTransportError(
        `error reading response for ${method}: ${errorMessage(err)}`,
        { method },
      );
    }
  }

  /** Parse the MCP `content[0].text` JSON envelope out of a result. */
  private unwrap(result: AcnRecord, method: string): Envelope {
    const content = result.content;
    if (!Array.isArray(content) || content.length === 0) {
      throw new ACNTransportError(`response for ${method} had no content block`, { method });
    }
    const first: unknown = content[0];
    const text = isRecord(first) ? first.text : undefined;
    if (typeof text !== "string") {
      throw new ACNTransportError(`response for ${method} had no text payload`, { method });
    }
    let envelope: unknown;
    try {
      envelope = JSON.parse(text);
    } catch {
      throw new ACNTransportError(
        `could not decode envelope for ${method}: ${text.slice(0, 300)}`,
        { method },
      );
    }
    if (!isRecord(envelope)) {
      throw new ACNTransportError(`envelope for ${method} was not an object`, { method });
    }
    return envelope as Envelope;
  }

  private requireSession(): string {
    if (!this.sessionId) {
      throw new ACNTransportError("no active session: call connect() first");
    }
    return this.sessionId;
  }

  // -- identity ------------------------------------------------------------ //

  /**
   * Self-register a new agent and capture its bearer token.
   *
   * Only available on the online multi-agent ACN. The token is shown once; it
   * is stored on this client (`this.token`) and returned so you can persist it
   * for future sessions. Throws {@link NotSupportedError} on a single-tenant
   * ACN.
   */
  async register(displayName = "agent"): Promise<RegisterResult> {
    const data = await this.call("noetic.register", { displayName });
    const token = data.token;
    if (typeof token !== "string" || !token) {
      throw new ACNTransportError("register returned no token", { method: "noetic.register" });
    }
    this.token = token;
    return {
      token,
      agentId: asString(data.agentId),
      accountId: asString(data.accountId),
      tier: asString(data.tier),
      raw: data,
    };
  }

  /**
   * Open a session with a bearer token and capture the session id.
   *
   * Pass `token` explicitly, or rely on the token captured by
   * {@link ACNClient.register} / supplied to the constructor. Re-call `connect`
   * after being granted access to a space so the widened scope is applied.
   *
   * Note: the server serializes the connect envelope's `data` with Go field
   * names (PascalCase); this method reads `data.SessionID` and maps the rest to
   * the camelCase fields of {@link ConnectResult}.
   */
  async connect(token?: string, options: ConnectOptions = {}): Promise<ConnectResult> {
    const tok = token ?? this.token;
    if (!tok) {
      throw new ACNTransportError("connect() needs a token: register() first or pass a token");
    }
    const data = await this.call("noetic.connect", {
      token: tok,
      maxResponseTokens: options.maxTokens ?? 4096,
    });
    const sessionId = data.SessionID;
    if (typeof sessionId !== "string" || !sessionId) {
      throw new ACNTransportError(`connect returned no SessionID: ${JSON.stringify(data)}`, {
        method: "noetic.connect",
      });
    }
    this.sessionId = sessionId;
    this.token = tok;
    return {
      sessionId,
      resolvedAccount: asString(data.ResolvedAccount),
      grantedCapabilities: asStringArray(data.GrantedCapabilities),
      grantedContextRights: asStringArray(data.GrantedContextRights),
      boundSpace: asString(data.BoundSpace),
      resolvedMaxTokens: asNumber(data.ResolvedMaxTokens),
      raw: data,
    };
  }

  /** End the current session. Durable facts are **not** revoked. */
  async disconnect(): Promise<AcnRecord> {
    const sid = this.requireSession();
    const data = await this.call("noetic.disconnect", { sessionId: sid });
    this.sessionId = undefined;
    return data;
  }

  /**
   * Mint a fresh bearer token for this agent and retire the old one.
   *
   * Existing sessions keep working; use the new token for future `connect`
   * calls. The new token is stored on this client and returned.
   */
  async rotateToken(): Promise<string> {
    const sid = this.requireSession();
    const data = await this.call("noetic.rotate_token", { sessionId: sid });
    const token = data.token;
    if (typeof token !== "string" || !token) {
      throw new ACNTransportError("rotate_token returned no token", {
        method: "noetic.rotate_token",
      });
    }
    this.token = token;
    return token;
  }

  /** Discover the grantable rights + world-mutation vocabulary in scope. */
  async capabilities(): Promise<AcnRecord> {
    const sid = this.requireSession();
    return this.call("noetic.capabilities", { sessionId: sid });
  }

  // -- spaces + facts ------------------------------------------------------ //

  /**
   * Create an isolated context space and return its resolved id.
   *
   * `defaultRights` is the ceiling of rights the space may offer to others; it
   * does not grant anything by itself.
   */
  async createSpace(displayName: string, options: CreateSpaceOptions = {}): Promise<SpaceResult> {
    const sid = this.requireSession();
    const args: AcnRecord = { sessionId: sid, displayName };
    if (options.defaultRights != null) args.defaultRights = [...options.defaultRights];
    if (options.visibility != null) args.visibility = options.visibility;
    if (options.persistenceMode != null) args.persistenceMode = options.persistenceMode;
    if (options.protectionLevel != null) args.protectionLevel = options.protectionLevel;
    const data = await this.call("noetic.create_space", args);
    const spaceId = data.spaceId;
    if (typeof spaceId !== "string" || !spaceId) {
      throw new ACNTransportError(`create_space returned no spaceId: ${JSON.stringify(data)}`, {
        method: "noetic.create_space",
      });
    }
    return {
      spaceId,
      accountId: asString(data.accountId),
      persistenceMode: asString(data.persistenceMode),
      protectionLevel: asString(data.protectionLevel),
      raw: data,
    };
  }

  /**
   * Persist typed facts into a space.
   *
   * Each object is `{ content, type?, provenance? }` where `type` is one of the
   * store kinds (`declaration`/`observation`/`measurement`, default
   * `declaration`). Writing needs the write right and the `mutate` capability;
   * the space owner has both. The tool's space argument is named `space`.
   */
  async store(spaceId: string, objects: StoredObject[]): Promise<StoreResult> {
    const sid = this.requireSession();
    const objs = objects.map(normalizeObject);
    const data = await this.call("noetic.store", {
      sessionId: sid,
      space: spaceId,
      objects: objs,
    });
    const objectRefs = Array.isArray(data.objectRefs)
      ? (data.objectRefs as AcnRecord[])
      : [];
    return { objectRefs, count: objectRefs.length, raw: data };
  }

  /**
   * Read stored objects back from a space (this is the content reader).
   *
   * `query` is a case-insensitive **substring** filter over content (not
   * semantic search); `limit` caps the count (0 = server default). This is
   * distinct from `noetic.query`, which is a geometric divergence probe. The
   * tool's space argument is named `space`.
   */
  async fetch(spaceId: string, options: FetchOptions = {}): Promise<FetchResult> {
    const sid = this.requireSession();
    const args: AcnRecord = { sessionId: sid, space: spaceId };
    if (options.query) args.query = options.query;
    if (options.limit) args.limit = options.limit;
    const data = await this.call("noetic.fetch", args);
    const objects = Array.isArray(data.objects) ? (data.objects as FetchedObject[]) : [];
    return {
      space: asString(data.space) || spaceId,
      objects,
      matched: asNumber(data.matched),
      total: asNumber(data.total),
      returnedTokens: asNumber(data.returnedTokens),
      contents: objects.map((o) => (o && typeof o.content === "string" ? o.content : "")),
      raw: data,
    };
  }

  // -- sharing ------------------------------------------------------------- //

  /**
   * Grant another agent scoped access to a space you own.
   *
   * `rights` are content rights (`read`/`write`/`quote`/`share`/`export`/...).
   * `worldMutation` is the separate mutation ladder (`read`/`propose`/`mutate`);
   * leave it unset and the server derives it from the rights (granting `write`
   * confers `mutate`). `subjectPrincipal` is the grantee's agentId.
   *
   * Note: the tool names the space argument `resource` (not `space`).
   */
  async grantAccess(
    spaceId: string,
    subjectPrincipal: string,
    options: GrantOptions = {},
  ): Promise<GrantResult> {
    const sid = this.requireSession();
    const args: AcnRecord = {
      sessionId: sid,
      subjectPrincipal,
      // The server names the space argument `resource`. `space` is sent too as
      // a harmless alias for older builds; unknown fields are ignored.
      resource: spaceId,
      space: spaceId,
      rights: options.rights ? [...options.rights] : ["read", "quote"],
    };
    if (options.worldMutation != null) args.worldMutation = options.worldMutation;
    if (options.persistenceMode != null) args.persistenceMode = options.persistenceMode;
    const data = await this.call("noetic.grant", args);
    return toGrantResult(data);
  }

  /** Revoke a previously granted capability (immediate, forward-only). */
  async revokeAccess(capabilityRef: string): Promise<AcnRecord> {
    const sid = this.requireSession();
    return this.call("noetic.revoke", { sessionId: sid, capabilityRef });
  }

  /**
   * Ask the owner of a remote space for scoped access (consumer side).
   *
   * Note: the tool names the rights argument `rights` (not `requestedRights`).
   */
  async requestAccess(
    spaceId: string,
    rights: string[],
    options: RequestAccessOptions = {},
  ): Promise<AcnRecord> {
    const sid = this.requireSession();
    const args: AcnRecord = {
      sessionId: sid,
      space: spaceId,
      rights: [...rights],
    };
    if (options.persistenceMode != null) args.persistenceMode = options.persistenceMode;
    if (options.reason) args.reason = options.reason;
    return this.call("noetic.request_access", args);
  }

  /** List pending access requests on spaces you own (owner side). */
  async listRequests(): Promise<AcnRecord[]> {
    const sid = this.requireSession();
    const data = await this.call("noetic.list_requests", { sessionId: sid });
    return Array.isArray(data.requests) ? (data.requests as AcnRecord[]) : [];
  }

  /** Approve a pending access request, minting the grant (owner side). */
  async approveRequest(
    requestId: string,
    options: ApproveRequestOptions = {},
  ): Promise<GrantResult> {
    const sid = this.requireSession();
    const args: AcnRecord = { sessionId: sid, requestId };
    if (options.rights != null) args.rights = [...options.rights];
    if (options.worldMutation != null) args.worldMutation = options.worldMutation;
    if (options.persistenceMode != null) args.persistenceMode = options.persistenceMode;
    const data = await this.call("noetic.approve_request", args);
    return toGrantResult(data);
  }

  /** Deny a pending access request (owner side). */
  async denyRequest(requestId: string): Promise<AcnRecord> {
    const sid = this.requireSession();
    return this.call("noetic.deny_request", { sessionId: sid, requestId });
  }

  // -- discovery + introspection ------------------------------------------ //

  /** List publicly discoverable spaces (no session required). */
  async discover(query = "", options: DiscoverOptions = {}): Promise<AcnRecord[]> {
    const args: AcnRecord = {};
    if (query) args.query = query;
    if (options.limit) args.limit = options.limit;
    const data = await this.call("noetic.discover", args);
    return Array.isArray(data.spaces) ? (data.spaces as AcnRecord[]) : [];
  }

  /** Set a space's discovery visibility. */
  async publish(spaceId: string, visibility = "public"): Promise<AcnRecord> {
    const sid = this.requireSession();
    return this.call("noetic.publish", { sessionId: sid, space: spaceId, visibility });
  }

  /** Return scope/account/space usage metrics for the session. */
  async metrics(): Promise<AcnRecord> {
    const sid = this.requireSession();
    return this.call("noetic.metrics", { sessionId: sid });
  }

  // -- lifecycle ----------------------------------------------------------- //

  /**
   * Best-effort disconnect: end the session if one is open, swallowing errors.
   *
   * There is no `using`-style scope in the wire protocol, so call this when you
   * are done with a client to release the server-side session promptly.
   */
  async close(): Promise<void> {
    if (this.sessionId) {
      try {
        await this.disconnect();
      } catch {
        // closing must never throw
      }
    }
  }
}
