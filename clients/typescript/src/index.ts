/**
 * Priostack Agent Context Network (ACN) — official TypeScript SDK.
 *
 * Model-agnostic, zero-setup long-term memory and multi-agent context sharing
 * for AI agents, over the Model Context Protocol (MCP).
 */

export { ACNClient, DEFAULT_ENDPOINT, VERSION } from "./client.js";

export {
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
  type Json,
  type RegisterResult,
  type RequestAccessOptions,
  type SpaceResult,
  type StoreKind,
  type StoreResult,
  type StoredObject,
} from "./types.js";

export {
  ACNError,
  ACNToolError,
  ACNTransportError,
  CapabilityDeniedError,
  CapacityExhaustedError,
  ConflictError,
  IntegrityFaultError,
  InvalidQueryError,
  NotFoundError,
  NotSupportedError,
  PolicyDeniedError,
  RequiresGovernanceError,
  StaleBaseError,
  toolErrorFor,
  type ToolErrorOptions,
  type ToolOutcome,
} from "./exceptions.js";
