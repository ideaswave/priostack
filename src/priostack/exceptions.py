"""Typed exceptions for the Priostack ACN client.

The ACN reports two very different kinds of failure and the client raises a
different branch of this hierarchy for each:

* **Transport / protocol failures** — the request never produced a valid
  tool envelope: a network error, an HTTP error status, malformed JSON, or a
  JSON-RPC ``error`` object (unknown method, bad params). These raise
  :class:`ACNTransportError`.

* **Tool failures** — the call reached the tool but the tool declined it: the
  envelope came back with ``ok: false`` and an ``outcome`` such as
  ``capability-denied`` or ``not-found``. These raise the matching subclass of
  :class:`ACNToolError`, so callers can catch exactly the outcome they expect::

      try:
          acn.store(space_id, objects=[...])
      except CapabilityDeniedError:
          ...  # the session lacks the write right / mutate capability

All exceptions derive from :class:`ACNError`, so ``except ACNError`` catches
everything the client can raise.
"""

from __future__ import annotations

from typing import Any, Dict, Optional


class ACNError(Exception):
    """Base class for every error raised by :class:`priostack.ACNClient`."""

    def __init__(self, message: str, *, method: Optional[str] = None) -> None:
        super().__init__(message)
        #: The tool name (``noetic.*``) the failing call targeted, if known.
        self.method = method


class ACNTransportError(ACNError):
    """A network, HTTP, decoding, or JSON-RPC protocol failure.

    Raised before a valid tool envelope could be obtained: connection errors,
    timeouts, non-2xx HTTP responses, non-JSON bodies, envelopes missing the
    ``content[0].text`` payload, or a JSON-RPC ``error`` object.
    """

    def __init__(
        self,
        message: str,
        *,
        method: Optional[str] = None,
        code: Optional[int] = None,
        http_status: Optional[int] = None,
    ) -> None:
        super().__init__(message, method=method)
        #: JSON-RPC error code, when the failure was a JSON-RPC ``error``.
        self.code = code
        #: HTTP status code, when the failure was an HTTP error.
        self.http_status = http_status


class ACNToolError(ACNError):
    """A tool declined the call (envelope ``ok: false``).

    Carries the server ``outcome`` string and human-readable ``detail``. Prefer
    catching a specific subclass; catch this base only when any tool-level
    failure should be handled the same way.
    """

    #: The ``outcome`` string this subclass corresponds to (set on subclasses).
    outcome: str = ""

    def __init__(
        self,
        detail: str,
        *,
        outcome: str = "",
        method: Optional[str] = None,
        data: Optional[Any] = None,
    ) -> None:
        super().__init__(detail or outcome or "ACN tool error", method=method)
        #: The server outcome (e.g. ``"capability-denied"``). Falls back to the
        #: class default when the server omitted it.
        self.outcome = outcome or type(self).outcome
        #: The server's ``detail`` message, if any.
        self.detail = detail
        #: Any partial ``data`` the server attached to the failure (e.g. the
        #: objects that were stored before a capacity fault).
        self.data = data


class NotFoundError(ACNToolError):
    """``not-found`` — no such session, space, or entity."""

    outcome = "not-found"


class InvalidQueryError(ACNToolError):
    """``invalid-query`` — malformed arguments or an unknown enum value."""

    outcome = "invalid-query"


class CapabilityDeniedError(ACNToolError):
    """``capability-denied`` — missing capability, or an invalid/revoked token."""

    outcome = "capability-denied"


class PolicyDeniedError(ACNToolError):
    """``policy-denied`` — a governance policy refused the operation."""

    outcome = "policy-denied"


class RequiresGovernanceError(ACNToolError):
    """``requires-governance`` — the change needs an explicit confirm step."""

    outcome = "requires-governance"


class StaleBaseError(ACNToolError):
    """``stale-base`` — the operation raced a newer state; re-read and retry."""

    outcome = "stale-base"


class IntegrityFaultError(ACNToolError):
    """``integrity-fault`` — an internal consistency check failed."""

    outcome = "integrity-fault"


class ConflictError(ACNToolError):
    """``conflict`` — the write conflicts with existing state."""

    outcome = "conflict"


class CapacityExhaustedError(ACNToolError):
    """``capacity-exhausted`` — a tier/registration/store ceiling was hit."""

    outcome = "capacity-exhausted"


class NotSupportedError(ACNToolError):
    """``not-implemented`` — the tool is unavailable on this ACN deployment.

    Most commonly: calling :meth:`~priostack.ACNClient.register` against a
    single-tenant/offline ACN that does not offer self-registration.
    """

    outcome = "not-implemented"


#: Maps a server ``outcome`` string to its :class:`ACNToolError` subclass.
_OUTCOME_MAP: Dict[str, type] = {
    cls.outcome: cls
    for cls in (
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
    )
}


def tool_error_for(
    outcome: str,
    detail: str,
    *,
    method: Optional[str] = None,
    data: Optional[Any] = None,
) -> ACNToolError:
    """Build the most specific :class:`ACNToolError` for a server ``outcome``.

    Unknown outcomes fall back to the :class:`ACNToolError` base so a new
    server outcome degrades gracefully instead of being mis-mapped.
    """
    cls = _OUTCOME_MAP.get(outcome, ACNToolError)
    return cls(detail, outcome=outcome, method=method, data=data)


__all__ = [
    "ACNError",
    "ACNTransportError",
    "ACNToolError",
    "NotFoundError",
    "InvalidQueryError",
    "CapabilityDeniedError",
    "PolicyDeniedError",
    "RequiresGovernanceError",
    "StaleBaseError",
    "IntegrityFaultError",
    "ConflictError",
    "CapacityExhaustedError",
    "NotSupportedError",
    "tool_error_for",
]
