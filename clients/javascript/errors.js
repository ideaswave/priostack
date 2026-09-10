'use strict';

/**
 * Typed errors for the Priostack ACN client.
 *
 * The ACN reports two very different kinds of failure and the client throws a
 * different branch of this hierarchy for each:
 *
 *   - Transport / protocol failures — the request never produced a valid tool
 *     envelope: a network error, an HTTP error status, malformed JSON, or a
 *     JSON-RPC `error` object (unknown method, bad params). These throw
 *     {@link ACNTransportError}.
 *
 *   - Tool failures — the call reached the tool but the tool declined it: the
 *     envelope came back with `ok: false` and an `outcome` such as
 *     `capability-denied` or `not-found`. These throw the matching subclass of
 *     {@link ACNToolError}, so callers can catch exactly the outcome they want:
 *
 *         try {
 *           await acn.store(spaceId, [...]);
 *         } catch (err) {
 *           if (err instanceof CapabilityDeniedError) {
 *             // the session lacks the write right / mutate capability
 *           }
 *         }
 *
 * Every error derives from {@link ACNError}, so `err instanceof ACNError`
 * catches everything the client can throw.
 */

/** Base class for every error thrown by {@link ACNClient}. */
class ACNError extends Error {
  constructor(message, { method = null } = {}) {
    super(message);
    this.name = 'ACNError';
    /** The tool name (`noetic.*`) the failing call targeted, if known. */
    this.method = method;
  }
}

/**
 * A network, HTTP, decoding, or JSON-RPC protocol failure.
 *
 * Thrown before a valid tool envelope could be obtained: connection errors,
 * timeouts, non-2xx HTTP responses, non-JSON bodies, envelopes missing the
 * `content[0].text` payload, or a JSON-RPC `error` object.
 */
class ACNTransportError extends ACNError {
  constructor(message, { method = null, code = null, httpStatus = null } = {}) {
    super(message, { method });
    this.name = 'ACNTransportError';
    /** JSON-RPC error code, when the failure was a JSON-RPC `error`. */
    this.code = code;
    /** HTTP status code, when the failure was an HTTP error. */
    this.httpStatus = httpStatus;
  }
}

/**
 * A tool declined the call (envelope `ok: false`).
 *
 * Carries the server `outcome` string and human-readable `detail`. Prefer
 * catching a specific subclass; catch this base only when any tool-level
 * failure should be handled the same way.
 */
class ACNToolError extends ACNError {
  constructor(detail, { outcome = '', method = null, data = null } = {}) {
    super(detail || outcome || 'ACN tool error', { method });
    // Report the concrete subclass name (e.g. "NotFoundError").
    this.name = new.target.name;
    /**
     * The server outcome (e.g. `"capability-denied"`). Falls back to the
     * subclass default when the server omitted it.
     */
    this.outcome = outcome || new.target.outcome || '';
    /** The server's `detail` message, if any. */
    this.detail = detail;
    /**
     * Any partial `data` the server attached to the failure (e.g. the objects
     * stored before a capacity fault).
     */
    this.data = data;
  }
}
/** The `outcome` string this subclass corresponds to (overridden per subclass). */
ACNToolError.outcome = '';

/** `not-found` — no such session, space, or entity. */
class NotFoundError extends ACNToolError {}
NotFoundError.outcome = 'not-found';

/** `invalid-query` — malformed arguments or an unknown enum value. */
class InvalidQueryError extends ACNToolError {}
InvalidQueryError.outcome = 'invalid-query';

/** `capability-denied` — missing capability, or an invalid/revoked token. */
class CapabilityDeniedError extends ACNToolError {}
CapabilityDeniedError.outcome = 'capability-denied';

/** `policy-denied` — a governance policy refused the operation. */
class PolicyDeniedError extends ACNToolError {}
PolicyDeniedError.outcome = 'policy-denied';

/** `requires-governance` — the change needs an explicit confirm step. */
class RequiresGovernanceError extends ACNToolError {}
RequiresGovernanceError.outcome = 'requires-governance';

/** `stale-base` — the operation raced a newer state; re-read and retry. */
class StaleBaseError extends ACNToolError {}
StaleBaseError.outcome = 'stale-base';

/** `integrity-fault` — an internal consistency check failed. */
class IntegrityFaultError extends ACNToolError {}
IntegrityFaultError.outcome = 'integrity-fault';

/** `conflict` — the write conflicts with existing state. */
class ConflictError extends ACNToolError {}
ConflictError.outcome = 'conflict';

/** `capacity-exhausted` — a tier/registration/store ceiling was hit. */
class CapacityExhaustedError extends ACNToolError {}
CapacityExhaustedError.outcome = 'capacity-exhausted';

/**
 * `not-implemented` — the tool is unavailable on this ACN deployment.
 *
 * Most commonly: calling `register()` against a single-tenant/offline ACN that
 * does not offer self-registration.
 */
class NotSupportedError extends ACNToolError {}
NotSupportedError.outcome = 'not-implemented';

/** Maps a server `outcome` string to its {@link ACNToolError} subclass. */
const OUTCOME_MAP = Object.freeze(
  Object.fromEntries(
    [
      NotFoundError,
      InvalidQueryError,
      CapabilityDeniedError,
      PolicyDeniedError,
      RequiresGovernanceError,
      StaleBaseError,
      IntegrityFaultError,
      ConflictError,
      CapacityExhaustedError,
      NotSupportedError,
    ].map((cls) => [cls.outcome, cls])
  )
);

/**
 * Build the most specific {@link ACNToolError} for a server `outcome`.
 *
 * Unknown outcomes fall back to the {@link ACNToolError} base so a new server
 * outcome degrades gracefully instead of being mis-mapped.
 *
 * @param {string} outcome
 * @param {string} detail
 * @param {{method?: string|null, data?: any}} [opts]
 * @returns {ACNToolError}
 */
function toolErrorFor(outcome, detail, { method = null, data = null } = {}) {
  const Cls = OUTCOME_MAP[outcome] || ACNToolError;
  return new Cls(detail, { outcome, method, data });
}

module.exports = {
  ACNError,
  ACNTransportError,
  ACNToolError,
  NotFoundError,
  InvalidQueryError,
  CapabilityDeniedError,
  PolicyDeniedError,
  RequiresGovernanceError,
  StaleBaseError,
  IntegrityFaultError,
  ConflictError,
  CapacityExhaustedError,
  NotSupportedError,
  toolErrorFor,
};
