/*
 * Typed exceptions for the Priostack ACN client.
 *
 * The ACN reports two very different kinds of failure and the client raises a
 * different branch of this hierarchy for each:
 *
 *  * Transport / protocol failures — the request never produced a valid tool
 *    envelope: a network error, an HTTP error status, malformed JSON, or a
 *    JSON-RPC `error` object (unknown method, bad params). These raise
 *    [AcnTransportError].
 *
 *  * Tool failures — the call reached the tool but the tool declined it: the
 *    envelope came back with `ok: false` and an `outcome` such as
 *    `capability-denied` or `not-found`. These raise the matching subclass of
 *    [AcnToolError], so callers can catch exactly the outcome they expect.
 *
 * Every exception derives from the sealed [AcnException], so a single
 * `catch (e: AcnException)` handles anything this client can raise.
 */
package com.priostack.acn

import kotlinx.serialization.json.JsonElement

/** Base class for every error raised by [AcnClient]. */
sealed class AcnException(
    message: String,
    /** The tool name (`noetic.*`) the failing call targeted, if known. */
    val method: String? = null,
    cause: Throwable? = null,
) : RuntimeException(message, cause)

/**
 * A network, HTTP, decoding, or JSON-RPC protocol failure.
 *
 * Raised before a valid tool envelope could be obtained: connection errors,
 * timeouts, non-2xx HTTP responses, non-JSON bodies, envelopes missing the
 * `content[0].text` payload, or a JSON-RPC `error` object.
 */
class AcnTransportError(
    message: String,
    method: String? = null,
    /** JSON-RPC error code, when the failure was a JSON-RPC `error`. */
    val code: Int? = null,
    /** HTTP status code, when the failure was an HTTP error. */
    val httpStatus: Int? = null,
    cause: Throwable? = null,
) : AcnException(message, method, cause)

/**
 * A tool declined the call (envelope `ok: false`).
 *
 * Carries the server [outcome] string and human-readable [detail]. Prefer
 * catching a specific subclass; catch this base only when any tool-level
 * failure should be handled the same way. An unrecognised outcome degrades to
 * this base class rather than being mis-mapped.
 */
open class AcnToolError internal constructor(
    /** The server outcome, e.g. `"capability-denied"`. */
    val outcome: String,
    /** The server's `detail` message, if any. */
    val detail: String,
    method: String? = null,
    /** Any partial `data` the server attached to the failure. */
    val data: JsonElement? = null,
) : AcnException(detail.ifEmpty { outcome.ifEmpty { "ACN tool error" } }, method)

/** `not-found` — no such session, space, or entity. */
class NotFoundError internal constructor(detail: String, method: String? = null, data: JsonElement? = null) :
    AcnToolError("not-found", detail, method, data)

/** `invalid-query` — malformed arguments or an unknown enum value. */
class InvalidQueryError internal constructor(detail: String, method: String? = null, data: JsonElement? = null) :
    AcnToolError("invalid-query", detail, method, data)

/** `capability-denied` — missing capability, or an invalid/revoked token. */
class CapabilityDeniedError internal constructor(detail: String, method: String? = null, data: JsonElement? = null) :
    AcnToolError("capability-denied", detail, method, data)

/** `policy-denied` — a governance policy refused the operation. */
class PolicyDeniedError internal constructor(detail: String, method: String? = null, data: JsonElement? = null) :
    AcnToolError("policy-denied", detail, method, data)

/** `requires-governance` — the change needs an explicit confirm step. */
class RequiresGovernanceError internal constructor(detail: String, method: String? = null, data: JsonElement? = null) :
    AcnToolError("requires-governance", detail, method, data)

/** `stale-base` — the operation raced a newer state; re-read and retry. */
class StaleBaseError internal constructor(detail: String, method: String? = null, data: JsonElement? = null) :
    AcnToolError("stale-base", detail, method, data)

/** `integrity-fault` — an internal consistency check failed. */
class IntegrityFaultError internal constructor(detail: String, method: String? = null, data: JsonElement? = null) :
    AcnToolError("integrity-fault", detail, method, data)

/** `conflict` — the write conflicts with existing state. */
class ConflictError internal constructor(detail: String, method: String? = null, data: JsonElement? = null) :
    AcnToolError("conflict", detail, method, data)

/** `capacity-exhausted` — a tier/registration/store ceiling was hit. */
class CapacityExhaustedError internal constructor(detail: String, method: String? = null, data: JsonElement? = null) :
    AcnToolError("capacity-exhausted", detail, method, data)

/**
 * `not-implemented` — the tool is unavailable on this ACN deployment.
 *
 * Most commonly: calling [AcnClient.register] against a single-tenant/offline
 * ACN that does not offer self-registration.
 */
class NotSupportedError internal constructor(detail: String, method: String? = null, data: JsonElement? = null) :
    AcnToolError("not-implemented", detail, method, data)

/**
 * Build the most specific [AcnToolError] for a server `outcome`. Unknown
 * outcomes fall back to the [AcnToolError] base so a new server outcome
 * degrades gracefully instead of being mis-mapped.
 */
internal fun toolErrorFor(
    outcome: String,
    detail: String,
    method: String? = null,
    data: JsonElement? = null,
): AcnToolError = when (outcome) {
    "not-found" -> NotFoundError(detail, method, data)
    "invalid-query" -> InvalidQueryError(detail, method, data)
    "capability-denied" -> CapabilityDeniedError(detail, method, data)
    "policy-denied" -> PolicyDeniedError(detail, method, data)
    "requires-governance" -> RequiresGovernanceError(detail, method, data)
    "stale-base" -> StaleBaseError(detail, method, data)
    "integrity-fault" -> IntegrityFaultError(detail, method, data)
    "conflict" -> ConflictError(detail, method, data)
    "capacity-exhausted" -> CapacityExhaustedError(detail, method, data)
    "not-implemented" -> NotSupportedError(detail, method, data)
    else -> AcnToolError(outcome, detail, method, data)
}
