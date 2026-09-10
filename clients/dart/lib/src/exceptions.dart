/// Typed exceptions for the Priostack ACN client.
///
/// The ACN reports two very different kinds of failure and the client throws a
/// different branch of this hierarchy for each:
///
/// * **Transport / protocol failures** — the request never produced a valid
///   tool envelope: a network error, an HTTP error status, malformed JSON, or a
///   JSON-RPC `error` object (unknown method, bad params). These throw
///   [AcnTransportError].
///
/// * **Tool failures** — the call reached the tool but the tool declined it:
///   the envelope came back with `ok: false` and an `outcome` such as
///   `capability-denied` or `not-found`. These throw the matching subclass of
///   [AcnToolError], so callers can catch exactly the outcome they expect:
///
/// ```dart
/// try {
///   await acn.store(spaceId, [/* ... */]);
/// } on CapabilityDeniedError {
///   // the session lacks the write right / mutate capability
/// }
/// ```
///
/// Every exception derives from [AcnError], so `on AcnError` catches everything
/// the client can throw.
library;

/// Base class for every error thrown by the ACN client.
class AcnError implements Exception {
  /// Creates an ACN error with a human-readable [message].
  AcnError(this.message, {this.method});

  /// The human-readable description of the failure.
  final String message;

  /// The tool name (`noetic.*`) the failing call targeted, if known.
  final String? method;

  @override
  String toString() {
    final where = method == null ? '' : ' [$method]';
    return '$runtimeType$where: $message';
  }
}

/// A network, HTTP, decoding, or JSON-RPC protocol failure.
///
/// Thrown before a valid tool envelope could be obtained: connection errors,
/// timeouts, non-2xx HTTP responses, non-JSON bodies, envelopes missing the
/// `content[0].text` payload, or a JSON-RPC `error` object.
class AcnTransportError extends AcnError {
  /// Creates a transport error, optionally carrying a JSON-RPC [code] or an
  /// HTTP [httpStatus].
  AcnTransportError(super.message, {super.method, this.code, this.httpStatus});

  /// JSON-RPC error code, when the failure was a JSON-RPC `error`.
  final int? code;

  /// HTTP status code, when the failure was an HTTP error.
  final int? httpStatus;
}

/// A tool declined the call (envelope `ok: false`).
///
/// Carries the server [outcome] string and human-readable [detail]. Prefer
/// catching a specific subclass; catch this base only when any tool-level
/// failure should be handled the same way.
class AcnToolError extends AcnError {
  /// Creates a tool error from the server's [detail] and [outcome].
  ///
  /// The [message] is derived from [detail], falling back to [outcome] and then
  /// a generic label so the error is never blank.
  AcnToolError(
    String detail, {
    String outcome = '',
    super.method,
    this.data,
  })  : detail = detail,
        outcome = outcome,
        super(
          detail.isNotEmpty ? detail : (outcome.isNotEmpty ? outcome : 'ACN tool error'),
        );

  /// The server outcome (e.g. `capability-denied`).
  final String outcome;

  /// The server's `detail` message, if any.
  final String detail;

  /// Any partial `data` the server attached to the failure (e.g. the objects
  /// that were stored before a capacity fault).
  final Object? data;
}

/// `not-found` — no such session, space, or entity.
class NotFoundError extends AcnToolError {
  /// Creates a `not-found` tool error.
  NotFoundError(super.detail, {super.method, super.data})
      : super(outcome: 'not-found');
}

/// `invalid-query` — malformed arguments or an unknown enum value.
class InvalidQueryError extends AcnToolError {
  /// Creates an `invalid-query` tool error.
  InvalidQueryError(super.detail, {super.method, super.data})
      : super(outcome: 'invalid-query');
}

/// `capability-denied` — missing capability, or an invalid/revoked token.
class CapabilityDeniedError extends AcnToolError {
  /// Creates a `capability-denied` tool error.
  CapabilityDeniedError(super.detail, {super.method, super.data})
      : super(outcome: 'capability-denied');
}

/// `policy-denied` — a governance policy refused the operation.
class PolicyDeniedError extends AcnToolError {
  /// Creates a `policy-denied` tool error.
  PolicyDeniedError(super.detail, {super.method, super.data})
      : super(outcome: 'policy-denied');
}

/// `requires-governance` — the change needs an explicit confirm step.
class RequiresGovernanceError extends AcnToolError {
  /// Creates a `requires-governance` tool error.
  RequiresGovernanceError(super.detail, {super.method, super.data})
      : super(outcome: 'requires-governance');
}

/// `stale-base` — the operation raced a newer state; re-read and retry.
class StaleBaseError extends AcnToolError {
  /// Creates a `stale-base` tool error.
  StaleBaseError(super.detail, {super.method, super.data})
      : super(outcome: 'stale-base');
}

/// `integrity-fault` — an internal consistency check failed.
class IntegrityFaultError extends AcnToolError {
  /// Creates an `integrity-fault` tool error.
  IntegrityFaultError(super.detail, {super.method, super.data})
      : super(outcome: 'integrity-fault');
}

/// `conflict` — the write conflicts with existing state.
class ConflictError extends AcnToolError {
  /// Creates a `conflict` tool error.
  ConflictError(super.detail, {super.method, super.data})
      : super(outcome: 'conflict');
}

/// `capacity-exhausted` — a tier/registration/store ceiling was hit.
class CapacityExhaustedError extends AcnToolError {
  /// Creates a `capacity-exhausted` tool error.
  CapacityExhaustedError(super.detail, {super.method, super.data})
      : super(outcome: 'capacity-exhausted');
}

/// `not-implemented` — the tool is unavailable on this ACN deployment.
///
/// Most commonly: calling `register` against a single-tenant/offline ACN that
/// does not offer self-registration.
class NotSupportedError extends AcnToolError {
  /// Creates a `not-implemented` tool error.
  NotSupportedError(super.detail, {super.method, super.data})
      : super(outcome: 'not-implemented');
}

typedef _ToolErrorCtor = AcnToolError Function(String detail, {String? method, Object? data});

const Map<String, _ToolErrorCtor> _outcomeCtors = {
  'not-found': NotFoundError.new,
  'invalid-query': InvalidQueryError.new,
  'capability-denied': CapabilityDeniedError.new,
  'policy-denied': PolicyDeniedError.new,
  'requires-governance': RequiresGovernanceError.new,
  'stale-base': StaleBaseError.new,
  'integrity-fault': IntegrityFaultError.new,
  'conflict': ConflictError.new,
  'capacity-exhausted': CapacityExhaustedError.new,
  'not-implemented': NotSupportedError.new,
};

/// Builds the most specific [AcnToolError] for a server [outcome].
///
/// Unknown outcomes fall back to the [AcnToolError] base (carrying the raw
/// [outcome]) so a new server outcome degrades gracefully instead of being
/// mis-mapped.
AcnToolError toolErrorFor(
  String outcome,
  String detail, {
  String? method,
  Object? data,
}) {
  final ctor = _outcomeCtors[outcome];
  if (ctor != null) return ctor(detail, method: method, data: data);
  return AcnToolError(detail, outcome: outcome, method: method, data: data);
}
