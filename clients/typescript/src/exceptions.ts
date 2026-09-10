/**
 * Typed errors for the Priostack ACN client.
 *
 * The ACN reports two very different kinds of failure and the client throws a
 * different branch of this hierarchy for each:
 *
 * - **Transport / protocol failures** — the request never produced a valid tool
 *   envelope: a network error, an HTTP error status, malformed JSON, or a
 *   JSON-RPC `error` object (unknown method, bad params). These throw
 *   {@link ACNTransportError}.
 *
 * - **Tool failures** — the call reached the tool but the tool declined it: the
 *   envelope came back with `ok: false` and an `outcome` such as
 *   `capability-denied` or `not-found`. These throw the matching subclass of
 *   {@link ACNToolError}, so callers can catch exactly the outcome they expect:
 *
 * ```ts
 * try {
 *   await acn.store(spaceId, [ ... ]);
 * } catch (err) {
 *   if (err instanceof CapabilityDeniedError) {
 *     // the session lacks the write right / mutate capability
 *   }
 * }
 * ```
 *
 * Everything derives from {@link ACNError}, so `err instanceof ACNError`
 * catches everything the client can throw.
 */

/** The set of tool `outcome` strings the server can return on `ok: false`. */
export type ToolOutcome =
  | "not-found"
  | "invalid-query"
  | "capability-denied"
  | "policy-denied"
  | "requires-governance"
  | "stale-base"
  | "integrity-fault"
  | "conflict"
  | "capacity-exhausted"
  | "not-implemented";

/** Base class for every error thrown by {@link ACNClient}. */
export class ACNError extends Error {
  /** The tool name (`noetic.*`) the failing call targeted, if known. */
  readonly method?: string;

  constructor(message: string, options: { method?: string } = {}) {
    super(message);
    // `new.target.name` resolves to the most-derived class, so every subclass
    // gets a correct `.name` without repeating it in each constructor.
    this.name = new.target.name;
    this.method = options.method;
  }
}

/**
 * A network, HTTP, decoding, or JSON-RPC protocol failure.
 *
 * Thrown before a valid tool envelope could be obtained: connection errors,
 * timeouts, non-2xx HTTP responses, non-JSON bodies, envelopes missing the
 * `content[0].text` payload, or a JSON-RPC `error` object.
 */
export class ACNTransportError extends ACNError {
  /** JSON-RPC error code, when the failure was a JSON-RPC `error`. */
  readonly code?: number;
  /** HTTP status code, when the failure was an HTTP error. */
  readonly httpStatus?: number;

  constructor(
    message: string,
    options: { method?: string; code?: number; httpStatus?: number } = {},
  ) {
    super(message, { method: options.method });
    this.code = options.code;
    this.httpStatus = options.httpStatus;
  }
}

/** Options accepted by every {@link ACNToolError}. */
export interface ToolErrorOptions {
  outcome?: string;
  method?: string;
  data?: unknown;
}

/**
 * A tool declined the call (envelope `ok: false`).
 *
 * Carries the server `outcome` string and human-readable `detail`. Prefer
 * catching a specific subclass; catch this base only when any tool-level
 * failure should be handled the same way.
 */
export class ACNToolError extends ACNError {
  /** The `outcome` string this subclass corresponds to (set on subclasses). */
  static readonly outcome: string = "";

  /** The server outcome (e.g. `"capability-denied"`). */
  readonly outcome: string;
  /** The server's `detail` message, if any. */
  readonly detail: string;
  /** Any partial `data` the server attached to the failure. */
  readonly data?: unknown;

  constructor(detail: string, options: ToolErrorOptions = {}) {
    const staticOutcome = (new.target as unknown as { outcome?: string }).outcome ?? "";
    const outcome = options.outcome || staticOutcome;
    super(detail || outcome || "ACN tool error", { method: options.method });
    this.outcome = outcome;
    this.detail = detail;
    this.data = options.data;
  }
}

/** `not-found` — no such session, space, or entity. */
export class NotFoundError extends ACNToolError {
  static override readonly outcome = "not-found";
}

/** `invalid-query` — malformed arguments or an unknown enum value. */
export class InvalidQueryError extends ACNToolError {
  static override readonly outcome = "invalid-query";
}

/** `capability-denied` — missing capability, or an invalid/revoked token. */
export class CapabilityDeniedError extends ACNToolError {
  static override readonly outcome = "capability-denied";
}

/** `policy-denied` — a governance policy refused the operation. */
export class PolicyDeniedError extends ACNToolError {
  static override readonly outcome = "policy-denied";
}

/** `requires-governance` — the change needs an explicit confirm step. */
export class RequiresGovernanceError extends ACNToolError {
  static override readonly outcome = "requires-governance";
}

/** `stale-base` — the operation raced a newer state; re-read and retry. */
export class StaleBaseError extends ACNToolError {
  static override readonly outcome = "stale-base";
}

/** `integrity-fault` — an internal consistency check failed. */
export class IntegrityFaultError extends ACNToolError {
  static override readonly outcome = "integrity-fault";
}

/** `conflict` — the write conflicts with existing state. */
export class ConflictError extends ACNToolError {
  static override readonly outcome = "conflict";
}

/** `capacity-exhausted` — a tier/registration/store ceiling was hit. */
export class CapacityExhaustedError extends ACNToolError {
  static override readonly outcome = "capacity-exhausted";
}

/**
 * `not-implemented` — the tool is unavailable on this ACN deployment.
 *
 * Most commonly: calling {@link ACNClient.register} against a
 * single-tenant/offline ACN that does not offer self-registration.
 */
export class NotSupportedError extends ACNToolError {
  static override readonly outcome = "not-implemented";
}

type ToolErrorCtor = new (detail: string, options?: ToolErrorOptions) => ACNToolError;

/** Maps a server `outcome` string to its {@link ACNToolError} subclass. */
const OUTCOME_MAP: Record<string, ToolErrorCtor> = {
  [NotFoundError.outcome]: NotFoundError,
  [InvalidQueryError.outcome]: InvalidQueryError,
  [CapabilityDeniedError.outcome]: CapabilityDeniedError,
  [PolicyDeniedError.outcome]: PolicyDeniedError,
  [RequiresGovernanceError.outcome]: RequiresGovernanceError,
  [StaleBaseError.outcome]: StaleBaseError,
  [IntegrityFaultError.outcome]: IntegrityFaultError,
  [ConflictError.outcome]: ConflictError,
  [CapacityExhaustedError.outcome]: CapacityExhaustedError,
  [NotSupportedError.outcome]: NotSupportedError,
};

/**
 * Build the most specific {@link ACNToolError} for a server `outcome`.
 *
 * Unknown outcomes fall back to the {@link ACNToolError} base so a new server
 * outcome degrades gracefully instead of being mis-mapped.
 */
export function toolErrorFor(
  outcome: string,
  detail: string,
  options: { method?: string; data?: unknown } = {},
): ACNToolError {
  const Ctor = OUTCOME_MAP[outcome] ?? ACNToolError;
  return new Ctor(detail, { outcome, method: options.method, data: options.data });
}
