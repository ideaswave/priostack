/**
 * Wire and result types for the Priostack ACN client.
 *
 * The server returns plain JSON. The `*Result` interfaces below give ergonomic,
 * type-checked access to the common calls while still exposing the full raw
 * `data` object via `.raw` for anything not surfaced as a field.
 */

/** A JSON value. */
export type Json = null | boolean | number | string | Json[] | { [key: string]: Json };

/** An arbitrary JSON object, as returned by the server. */
export type AcnRecord = Record<string, unknown>;

/**
 * Object `type` values the `store` tool accepts. Anything else is rejected
 * server-side with `invalid-query` (proposals/inferences go through the
 * propose/commit path, not `store`).
 */
export const STORE_KINDS = ["declaration", "observation", "measurement"] as const;

/** One of the accepted {@link STORE_KINDS}. */
export type StoreKind = (typeof STORE_KINDS)[number];

/** The MCP tool envelope carried inside `result.content[0].text`. */
export interface Envelope {
  ok?: boolean;
  outcome?: string;
  data?: unknown;
  detail?: string;
  receipt?: unknown;
}

/** A fact to persist with {@link ACNClient.store}. */
export interface StoredObject {
  /** The fact's content. Required. */
  content: string;
  /** The fact's kind. Defaults to `"declaration"`. */
  type?: StoreKind;
  /** Optional provenance references. */
  provenance?: unknown[];
}

/** A fact read back by {@link ACNClient.fetch}. */
export interface FetchedObject {
  objectRef: string;
  kind: string;
  content: string;
  tokens: number;
}

/** Result of {@link ACNClient.register}. */
export interface RegisterResult {
  token: string;
  agentId: string;
  accountId: string;
  tier: string;
  raw: AcnRecord;
}

/**
 * Result of {@link ACNClient.connect}.
 *
 * Note: the server serializes this envelope's `data` with Go field names
 * (PascalCase); the client maps them to these camelCase fields for you.
 */
export interface ConnectResult {
  sessionId: string;
  resolvedAccount: string;
  grantedCapabilities: string[];
  grantedContextRights: string[];
  boundSpace: string;
  resolvedMaxTokens: number;
  raw: AcnRecord;
}

/** Result of {@link ACNClient.createSpace}. */
export interface SpaceResult {
  spaceId: string;
  accountId: string;
  persistenceMode: string;
  protectionLevel: string;
  raw: AcnRecord;
}

/** Result of {@link ACNClient.store}. */
export interface StoreResult {
  objectRefs: AcnRecord[];
  /** How many objects were ingested. */
  count: number;
  raw: AcnRecord;
}

/** Result of {@link ACNClient.fetch}. */
export interface FetchResult {
  space: string;
  objects: FetchedObject[];
  matched: number;
  total: number;
  returnedTokens: number;
  /** Just the `content` strings of the returned objects. */
  contents: string[];
  raw: AcnRecord;
}

/** Result of {@link ACNClient.grantAccess} / {@link ACNClient.approveRequest}. */
export interface GrantResult {
  capabilityRef: string;
  subject: string;
  resource: string;
  effectiveRights: string[];
  raw: AcnRecord;
}

/** Options for the {@link ACNClient} constructor. */
export interface ACNClientOptions {
  /**
   * Base RPC URL. Defaults to the canonical Streamable-HTTP MCP endpoint
   * `https://priostack.com/mcp`. The legacy `.../acn/rpc` path is an alias.
   */
  endpoint?: string;
  /**
   * A previously issued bearer token, to reconnect an existing agent without
   * registering again. Optional; {@link ACNClient.register} sets it.
   */
  token?: string;
  /** Per-request timeout in milliseconds. Defaults to 30000. */
  timeoutMs?: number;
  /**
   * A `fetch` implementation to use. Defaults to the runtime's global `fetch`
   * (Node 18+, Deno, Bun, browsers). Inject one to customize TLS, proxies, etc.
   */
  fetch?: typeof fetch;
  /** Extra headers merged into every request. */
  headers?: Record<string, string>;
}

/** Options for {@link ACNClient.connect}. */
export interface ConnectOptions {
  maxTokens?: number;
}

/** Options for {@link ACNClient.createSpace}. */
export interface CreateSpaceOptions {
  defaultRights?: string[];
  visibility?: string;
  persistenceMode?: string;
  protectionLevel?: string;
}

/** Options for {@link ACNClient.fetch}. */
export interface FetchOptions {
  /** Case-insensitive substring filter over content (not semantic search). */
  query?: string;
  /** Cap on the number of objects returned (0 = server default). */
  limit?: number;
}

/** Options for {@link ACNClient.grantAccess}. */
export interface GrantOptions {
  rights?: string[];
  worldMutation?: string;
  persistenceMode?: string;
}

/** Options for {@link ACNClient.requestAccess}. */
export interface RequestAccessOptions {
  reason?: string;
  persistenceMode?: string;
}

/** Options for {@link ACNClient.approveRequest}. */
export interface ApproveRequestOptions {
  rights?: string[];
  worldMutation?: string;
  persistenceMode?: string;
}

/** Options for {@link ACNClient.discover}. */
export interface DiscoverOptions {
  limit?: number;
}
