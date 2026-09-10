package com.priostack.acn

/** Typed errors for the Priostack ACN client.
  *
  * The ACN reports two very different kinds of failure and the client raises a
  * different branch of this hierarchy for each:
  *
  *   - '''Transport / protocol failures''' — the request never produced a valid
  *     tool envelope: a network error, an HTTP error status, malformed JSON, or
  *     a JSON-RPC `error` object (unknown method, bad params). These raise
  *     [[AcnTransportError]].
  *   - '''Tool failures''' — the call reached the tool but the tool declined it:
  *     the envelope came back with `ok: false` and an `outcome` such as
  *     `capability-denied` or `not-found`. These raise the matching subclass of
  *     [[AcnToolError]], so callers can catch exactly the outcome they expect.
  *
  * Every error derives from [[AcnError]], so a single `catch { case _: AcnError }`
  * covers everything the client can raise.
  */
abstract class AcnError(
    message: String,
    val method: Option[String] = None,
    cause: Throwable = null
) extends RuntimeException(message, cause)

/** A network, HTTP, decoding, or JSON-RPC protocol failure.
  *
  * Raised before a valid tool envelope could be obtained: connection errors,
  * timeouts, non-2xx HTTP responses, non-JSON bodies, envelopes missing the
  * `content[0].text` payload, or a JSON-RPC `error` object.
  */
final class AcnTransportError(
    message: String,
    method: Option[String] = None,
    val code: Option[Int] = None,
    val httpStatus: Option[Int] = None,
    cause: Throwable = null
) extends AcnError(message, method, cause)

/** A tool declined the call (envelope `ok: false`).
  *
  * Carries the server `outcome` string and human-readable `detail`. Prefer
  * catching a specific subclass; catch this base only when any tool-level
  * failure should be handled the same way. Unknown outcomes (e.g. a new server
  * outcome) surface as this base class rather than being mis-mapped.
  */
class AcnToolError(
    val detail: String,
    val outcome: String,
    method: Option[String] = None,
    val data: Option[ujson.Value] = None
) extends AcnError(
      if (detail.nonEmpty) detail else if (outcome.nonEmpty) outcome else "ACN tool error",
      method
    )

/** `not-found` — no such session, space, or entity. */
final class NotFoundError(detail: String, method: Option[String] = None, data: Option[ujson.Value] = None)
    extends AcnToolError(detail, "not-found", method, data)

/** `invalid-query` — malformed arguments or an unknown enum value. */
final class InvalidQueryError(detail: String, method: Option[String] = None, data: Option[ujson.Value] = None)
    extends AcnToolError(detail, "invalid-query", method, data)

/** `capability-denied` — missing capability, or an invalid/revoked token. */
final class CapabilityDeniedError(detail: String, method: Option[String] = None, data: Option[ujson.Value] = None)
    extends AcnToolError(detail, "capability-denied", method, data)

/** `policy-denied` — a governance policy refused the operation. */
final class PolicyDeniedError(detail: String, method: Option[String] = None, data: Option[ujson.Value] = None)
    extends AcnToolError(detail, "policy-denied", method, data)

/** `requires-governance` — the change needs an explicit confirm step. */
final class RequiresGovernanceError(detail: String, method: Option[String] = None, data: Option[ujson.Value] = None)
    extends AcnToolError(detail, "requires-governance", method, data)

/** `stale-base` — the operation raced a newer state; re-read and retry. */
final class StaleBaseError(detail: String, method: Option[String] = None, data: Option[ujson.Value] = None)
    extends AcnToolError(detail, "stale-base", method, data)

/** `integrity-fault` — an internal consistency check failed. */
final class IntegrityFaultError(detail: String, method: Option[String] = None, data: Option[ujson.Value] = None)
    extends AcnToolError(detail, "integrity-fault", method, data)

/** `conflict` — the write conflicts with existing state. */
final class ConflictError(detail: String, method: Option[String] = None, data: Option[ujson.Value] = None)
    extends AcnToolError(detail, "conflict", method, data)

/** `capacity-exhausted` — a tier/registration/store ceiling was hit. */
final class CapacityExhaustedError(detail: String, method: Option[String] = None, data: Option[ujson.Value] = None)
    extends AcnToolError(detail, "capacity-exhausted", method, data)

/** `not-implemented` — the tool is unavailable on this ACN deployment.
  *
  * Most commonly: calling [[AcnClient.register]] against a single-tenant/offline
  * ACN that does not offer self-registration.
  */
final class NotSupportedError(detail: String, method: Option[String] = None, data: Option[ujson.Value] = None)
    extends AcnToolError(detail, "not-implemented", method, data)

object AcnToolError:
  /** Build the most specific [[AcnToolError]] for a server `outcome`. Unknown
    * outcomes fall back to the [[AcnToolError]] base so a new server outcome
    * degrades gracefully instead of being mis-mapped.
    */
  def apply(
      outcome: String,
      detail: String,
      method: Option[String] = None,
      data: Option[ujson.Value] = None
  ): AcnToolError =
    outcome match
      case "not-found"           => new NotFoundError(detail, method, data)
      case "invalid-query"       => new InvalidQueryError(detail, method, data)
      case "capability-denied"   => new CapabilityDeniedError(detail, method, data)
      case "policy-denied"       => new PolicyDeniedError(detail, method, data)
      case "requires-governance" => new RequiresGovernanceError(detail, method, data)
      case "stale-base"          => new StaleBaseError(detail, method, data)
      case "integrity-fault"     => new IntegrityFaultError(detail, method, data)
      case "conflict"            => new ConflictError(detail, method, data)
      case "capacity-exhausted"  => new CapacityExhaustedError(detail, method, data)
      case "not-implemented"     => new NotSupportedError(detail, method, data)
      case _                     => new AcnToolError(detail, outcome, method, data)
