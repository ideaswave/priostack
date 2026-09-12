"""Official Python client for the Priostack Agent Context Network (ACN).

The ACN is a Model Context Protocol (MCP) server reached over JSON-RPC 2.0. An
agent self-registers, opens a session with the returned bearer token, creates
isolated context spaces, stores typed facts, reads them back, and shares them
with other agents through scoped capability grants.

This client speaks the exact wire contract of the live server: it unwraps the
MCP ``result.content[0].text`` envelope, raises typed exceptions on tool-level
denials, reuses one pooled HTTPS connection, retries transient network faults
with backoff, and captures the session id automatically on
:meth:`~ACNClient.connect`.

Quickstart::

    from priostack import ACNClient

    with ACNClient() as acn:
        acn.register(display_name="my-agent")   # token captured internally
        acn.connect()                           # session id captured internally
        space = acn.create_space(display_name="prod-memory")
        acn.store(space.space_id, objects=[
            {"content": "Refunds over $500 need manager approval.", "type": "declaration"},
        ])
        hits = acn.fetch(space.space_id, query="refund")
        for obj in hits.objects:
            print(obj["content"])
"""

from __future__ import annotations

import itertools
import json
import os
import threading
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional, Sequence, Union

import requests
from requests.adapters import HTTPAdapter

try:  # urllib3 ships with requests; import defensively across versions.
    from urllib3.util.retry import Retry
except Exception:  # pragma: no cover - extremely old requests
    from requests.packages.urllib3.util.retry import Retry  # type: ignore

from .exceptions import ACNTransportError, tool_error_for

__all__ = [
    "ACNClient",
    "RegisterResult",
    "ConnectResult",
    "SpaceResult",
    "StoreResult",
    "FetchResult",
    "GrantResult",
]

#: Canonical MCP endpoint (Streamable HTTP). ``/acn/rpc`` is a working alias.
DEFAULT_ENDPOINT = "https://priostack.com/mcp"

#: Environment override for the endpoint, read when none is passed to
#: :class:`ACNClient`. Same variable the other language clients read. Point it at
#: a self-hosted node or a local one (``http://127.0.0.1:8091/rpc``) and every
#: example in this repository follows, unedited.
ENDPOINT_ENV_VAR = "PRIOSTACK_ENDPOINT"

#: Object ``type`` values the ``store`` tool accepts. Anything else is rejected
#: server-side with ``invalid-query`` (proposals/inferences go through the
#: propose/commit path, not ``store``).
STORE_KINDS = ("declaration", "observation", "measurement")


# --------------------------------------------------------------------------- #
# Typed result objects
#
# The server returns plain JSON. These lightweight dataclasses give ergonomic,
# type-checked access to the common calls while still exposing the full raw
# ``data`` dict via ``.raw`` for anything not surfaced as an attribute.
# --------------------------------------------------------------------------- #
@dataclass
class RegisterResult:
    """Result of :meth:`ACNClient.register`."""

    token: str
    agent_id: str
    account_id: str
    tier: str
    raw: Dict[str, Any] = field(default_factory=dict, repr=False)


@dataclass
class ConnectResult:
    """Result of :meth:`ACNClient.connect`. Note the server uses PascalCase."""

    session_id: str
    resolved_account: str
    granted_capabilities: List[str]
    granted_context_rights: List[str]
    bound_space: str
    resolved_max_tokens: int
    raw: Dict[str, Any] = field(default_factory=dict, repr=False)


@dataclass
class SpaceResult:
    """Result of :meth:`ACNClient.create_space`."""

    space_id: str
    account_id: str
    persistence_mode: str
    protection_level: str
    raw: Dict[str, Any] = field(default_factory=dict, repr=False)


@dataclass
class StoreResult:
    """Result of :meth:`ACNClient.store`."""

    object_refs: List[Dict[str, Any]]
    raw: Dict[str, Any] = field(default_factory=dict, repr=False)

    @property
    def count(self) -> int:
        """How many objects were ingested."""
        return len(self.object_refs)


@dataclass
class FetchResult:
    """Result of :meth:`ACNClient.fetch`."""

    space: str
    objects: List[Dict[str, Any]]
    matched: int
    total: int
    returned_tokens: int
    raw: Dict[str, Any] = field(default_factory=dict, repr=False)

    def contents(self) -> List[str]:
        """Just the ``content`` strings of the returned objects."""
        return [o.get("content", "") for o in self.objects]


@dataclass
class GrantResult:
    """Result of :meth:`ACNClient.grant_access` / :meth:`ACNClient.approve_request`."""

    capability_ref: str
    subject: str
    resource: str
    effective_rights: List[str]
    raw: Dict[str, Any] = field(default_factory=dict, repr=False)


class ACNClient:
    """A sturdy JSON-RPC client for the Priostack ACN.

    Parameters
    ----------
    endpoint:
        Base RPC URL. When omitted, the ``PRIOSTACK_ENDPOINT`` environment
        variable is used, and failing that the canonical Streamable-HTTP MCP
        endpoint ``https://priostack.com/mcp``. The legacy ``.../acn/rpc`` path
        is an accepted alias.
    token:
        A previously issued bearer token, to reconnect an existing agent
        without registering again. Optional; :meth:`register` sets it.
    timeout:
        Per-request timeout in seconds (connect, read) applied to every call.
    max_retries:
        How many times to retry *transport* faults. Only connection errors and
        explicit back-pressure statuses (429, 503) are retried; read timeouts
        are **not** retried, so a non-idempotent call such as ``store`` is never
        silently duplicated.
    backoff_factor:
        Exponential backoff base (seconds) between retries.
    session:
        Inject a pre-built :class:`requests.Session` (e.g. with custom auth,
        proxies, or TLS settings). When omitted, one is created and pooled.
    """

    def __init__(
        self,
        endpoint: Optional[str] = None,
        *,
        token: Optional[str] = None,
        timeout: Union[float, tuple] = 30.0,
        max_retries: int = 3,
        backoff_factor: float = 0.5,
        session: Optional[requests.Session] = None,
    ) -> None:
        self.endpoint = endpoint or os.environ.get(ENDPOINT_ENV_VAR) or DEFAULT_ENDPOINT
        self.timeout = timeout
        self.token: Optional[str] = token
        self.session_id: Optional[str] = None

        self._ids = itertools.count(1)
        self._id_lock = threading.Lock()

        self._owns_session = session is None
        self._http = session or requests.Session()
        if self._owns_session:
            self._configure_retries(max_retries, backoff_factor)
        self._http.headers.update(
            {
                "Content-Type": "application/json",
                # Ask for a plain JSON reply; the Streamable-HTTP endpoint would
                # otherwise be free to answer a POST as a one-shot SSE frame.
                "Accept": "application/json",
                "User-Agent": self._user_agent(),
            }
        )

    # -- lifecycle --------------------------------------------------------- #
    def __enter__(self) -> "ACNClient":
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        self.close()

    def close(self) -> None:
        """Best-effort disconnect (if connected) and release the HTTP pool."""
        try:
            if self.session_id:
                self.disconnect()
        except Exception:
            pass  # closing must never raise
        finally:
            if self._owns_session:
                self._http.close()

    @property
    def connected(self) -> bool:
        """Whether a session id has been captured."""
        return self.session_id is not None

    # -- transport --------------------------------------------------------- #
    def _configure_retries(self, total: int, backoff_factor: float) -> None:
        # read=0: never retry after the request body was sent, so a store that
        # the server may already have applied is not resent. connect retries are
        # safe (the request never reached the server). 429/503 are back-pressure
        # signals the server emits before doing work, so they are safe to retry.
        retry = Retry(
            total=total,
            connect=total,
            read=0,
            status=total,
            status_forcelist=(429, 503),
            allowed_methods=frozenset(["POST"]),
            backoff_factor=backoff_factor,
            respect_retry_after_header=True,
            raise_on_status=False,
        )
        adapter = HTTPAdapter(max_retries=retry, pool_connections=4, pool_maxsize=8)
        self._http.mount("https://", adapter)
        self._http.mount("http://", adapter)

    @staticmethod
    def _user_agent() -> str:
        try:
            from . import __version__
        except Exception:  # pragma: no cover
            __version__ = "0"
        return f"priostack-python/{__version__}"

    def _next_id(self) -> int:
        with self._id_lock:
            return next(self._ids)

    def call(self, method: str, arguments: Dict[str, Any]) -> Dict[str, Any]:
        """Invoke any ``noetic.*`` tool and return its unwrapped ``data`` dict.

        This is the low-level escape hatch behind every typed method — use it to
        reach tools this client does not wrap explicitly (there are ~40). It
        performs the full round trip: builds the JSON-RPC ``tools/call``
        envelope, unwraps ``result.content[0].text``, and raises
        :class:`~priostack.exceptions.ACNToolError` (or a subclass) when the
        tool returns ``ok: false``.
        """
        payload = {
            "jsonrpc": "2.0",
            "id": self._next_id(),
            "method": "tools/call",
            "params": {"name": method, "arguments": arguments},
        }
        try:
            resp = self._http.post(self.endpoint, json=payload, timeout=self.timeout)
        except requests.RequestException as exc:
            raise ACNTransportError(
                f"network error calling {method}: {exc}", method=method
            ) from exc

        if resp.status_code >= 400:
            raise ACNTransportError(
                f"HTTP {resp.status_code} calling {method}: {resp.text[:500]}",
                method=method,
                http_status=resp.status_code,
            )

        try:
            body = resp.json()
        except ValueError as exc:
            raise ACNTransportError(
                f"non-JSON response calling {method}: {resp.text[:500]}", method=method
            ) from exc

        # JSON-RPC protocol error (unknown method, bad params) — no result.
        if isinstance(body, dict) and body.get("error"):
            err = body["error"]
            raise ACNTransportError(
                f"JSON-RPC error calling {method}: {err.get('message', err)}",
                method=method,
                code=err.get("code"),
            )

        result = body.get("result") if isinstance(body, dict) else None
        if not isinstance(result, dict):
            raise ACNTransportError(
                f"malformed response calling {method}: {str(body)[:500]}", method=method
            )

        envelope = self._unwrap(result, method)

        if not envelope.get("ok", False):
            raise tool_error_for(
                envelope.get("outcome", ""),
                envelope.get("detail", ""),
                method=method,
                data=envelope.get("data"),
            )
        # ``data`` is optional (some tools return ok with no payload).
        data = envelope.get("data")
        return data if isinstance(data, dict) else {"data": data}

    @staticmethod
    def _unwrap(result: Dict[str, Any], method: str) -> Dict[str, Any]:
        """Parse the MCP ``content[0].text`` JSON envelope out of a result."""
        content = result.get("content")
        if not isinstance(content, list) or not content:
            raise ACNTransportError(
                f"response for {method} had no content block", method=method
            )
        text = content[0].get("text") if isinstance(content[0], dict) else None
        if not isinstance(text, str):
            raise ACNTransportError(
                f"response for {method} had no text payload", method=method
            )
        try:
            envelope = json.loads(text)
        except ValueError as exc:
            raise ACNTransportError(
                f"could not decode envelope for {method}: {text[:300]}", method=method
            ) from exc
        if not isinstance(envelope, dict):
            raise ACNTransportError(
                f"envelope for {method} was not an object", method=method
            )
        return envelope

    def _require_session(self) -> str:
        if not self.session_id:
            raise ACNTransportError(
                "no active session: call connect() first",
            )
        return self.session_id

    # -- identity ---------------------------------------------------------- #
    def register(self, display_name: str = "agent") -> RegisterResult:
        """Self-register a new agent and capture its bearer token.

        Only available on the online multi-agent ACN. The token is shown once;
        it is stored on this client (``self.token``) and returned so you can
        persist it for future sessions. Raises
        :class:`~priostack.exceptions.NotSupportedError` on a single-tenant ACN.
        """
        data = self.call("noetic.register", {"displayName": display_name})
        self.token = data["token"]
        return RegisterResult(
            token=data["token"],
            agent_id=data.get("agentId", ""),
            account_id=data.get("accountId", ""),
            tier=data.get("tier", ""),
            raw=data,
        )

    def connect(
        self, token: Optional[str] = None, *, max_tokens: int = 4096
    ) -> ConnectResult:
        """Open a session with a bearer token and capture the session id.

        Pass ``token`` explicitly, or rely on the token captured by
        :meth:`register` / passed to the constructor. Re-call ``connect`` after
        being granted access to a space so the widened scope is applied.
        """
        tok = token or self.token
        if not tok:
            raise ACNTransportError(
                "connect() needs a token: register() first or pass token=..."
            )
        data = self.call(
            "noetic.connect", {"token": tok, "maxResponseTokens": max_tokens}
        )
        # The server serializes ConnectResult with Go field names (PascalCase).
        self.session_id = data.get("SessionID")
        self.token = tok
        if not self.session_id:
            raise ACNTransportError(
                f"connect returned no SessionID: {data}", method="noetic.connect"
            )
        return ConnectResult(
            session_id=self.session_id,
            resolved_account=data.get("ResolvedAccount", ""),
            granted_capabilities=data.get("GrantedCapabilities") or [],
            granted_context_rights=data.get("GrantedContextRights") or [],
            bound_space=data.get("BoundSpace", ""),
            resolved_max_tokens=data.get("ResolvedMaxTokens", 0),
            raw=data,
        )

    def disconnect(self) -> Dict[str, Any]:
        """End the current session. Durable facts are **not** revoked."""
        sid = self._require_session()
        data = self.call("noetic.disconnect", {"sessionId": sid})
        self.session_id = None
        return data

    def rotate_token(self) -> str:
        """Mint a fresh bearer token for this agent and retire the old one.

        Existing sessions keep working; use the new token for future
        ``connect`` calls. The new token is stored on this client and returned.
        """
        sid = self._require_session()
        data = self.call("noetic.rotate_token", {"sessionId": sid})
        self.token = data["token"]
        return data["token"]

    def capabilities(self) -> Dict[str, Any]:
        """Discover the grantable rights + world-mutation vocabulary in scope."""
        sid = self._require_session()
        return self.call("noetic.capabilities", {"sessionId": sid})

    # -- spaces + facts ---------------------------------------------------- #
    def create_space(
        self,
        display_name: str,
        *,
        default_rights: Optional[Sequence[str]] = None,
        visibility: Optional[str] = None,
        persistence_mode: Optional[str] = None,
        protection_level: Optional[str] = None,
    ) -> SpaceResult:
        """Create an isolated context space and return its resolved id.

        ``default_rights`` is the ceiling of rights the space may offer to
        others; it does not grant anything by itself.
        """
        sid = self._require_session()
        args: Dict[str, Any] = {"sessionId": sid, "displayName": display_name}
        if default_rights is not None:
            args["defaultRights"] = list(default_rights)
        if visibility is not None:
            args["visibility"] = visibility
        if persistence_mode is not None:
            args["persistenceMode"] = persistence_mode
        if protection_level is not None:
            args["protectionLevel"] = protection_level
        data = self.call("noetic.create_space", args)
        return SpaceResult(
            space_id=data["spaceId"],
            account_id=data.get("accountId", ""),
            persistence_mode=data.get("persistenceMode", ""),
            protection_level=data.get("protectionLevel", ""),
            raw=data,
        )

    def store(
        self, space_id: str, objects: Sequence[Dict[str, Any]]
    ) -> StoreResult:
        """Persist typed facts into a space.

        Each object is ``{"content": str, "type": <kind>, "provenance"?: [...]}``
        where ``type`` is one of :data:`STORE_KINDS`
        (``declaration``/``observation``/``measurement``). Writing needs the
        write right and the ``mutate`` capability; the space owner has both.
        """
        sid = self._require_session()
        objs = [self._normalize_object(o) for o in objects]
        data = self.call(
            "noetic.store", {"sessionId": sid, "space": space_id, "objects": objs}
        )
        return StoreResult(object_refs=data.get("objectRefs") or [], raw=data)

    @staticmethod
    def _normalize_object(obj: Dict[str, Any]) -> Dict[str, Any]:
        if "content" not in obj:
            raise ValueError("each stored object needs a 'content' field")
        kind = obj.get("type", "declaration")
        if kind not in STORE_KINDS:
            raise ValueError(
                f"invalid object type {kind!r}; must be one of {STORE_KINDS}"
            )
        out: Dict[str, Any] = {"content": obj["content"], "type": kind}
        if obj.get("provenance"):
            out["provenance"] = list(obj["provenance"])
        return out

    def fetch(
        self, space_id: str, *, query: str = "", limit: int = 0
    ) -> FetchResult:
        """Read stored objects back from a space (this is the content reader).

        ``query`` is a case-insensitive **substring** filter over content (not
        semantic search); ``limit`` caps the count (0 = server default). This is
        distinct from ``noetic.query``, which is a geometric divergence probe.
        """
        sid = self._require_session()
        args: Dict[str, Any] = {"sessionId": sid, "space": space_id}
        if query:
            args["query"] = query
        if limit:
            args["limit"] = limit
        data = self.call("noetic.fetch", args)
        return FetchResult(
            space=data.get("space", space_id),
            objects=data.get("objects") or [],
            matched=data.get("matched", 0),
            total=data.get("total", 0),
            returned_tokens=data.get("returnedTokens", 0),
            raw=data,
        )

    # -- sharing ----------------------------------------------------------- #
    def grant_access(
        self,
        space_id: str,
        subject_principal: str,
        *,
        rights: Sequence[str] = ("read", "quote"),
        world_mutation: Optional[str] = None,
        persistence_mode: Optional[str] = None,
    ) -> GrantResult:
        """Grant another agent scoped access to a space you own.

        ``rights`` are content rights (``read``/``write``/``quote``/``share``/
        ``export``/...). ``world_mutation`` is the separate mutation ladder
        (``read``/``propose``/``mutate``); leave it ``None`` and the server
        derives it from the rights (granting ``write`` confers ``mutate``).
        """
        sid = self._require_session()
        # The server names the space argument ``resource``. ``space`` is sent
        # too as a harmless alias for older builds; unknown fields are ignored.
        args: Dict[str, Any] = {
            "sessionId": sid,
            "subjectPrincipal": subject_principal,
            "resource": space_id,
            "space": space_id,
            "rights": list(rights),
        }
        if world_mutation is not None:
            args["worldMutation"] = world_mutation
        if persistence_mode is not None:
            args["persistenceMode"] = persistence_mode
        data = self.call("noetic.grant", args)
        return self._grant_result(data)

    def revoke_access(self, capability_ref: str) -> Dict[str, Any]:
        """Revoke a previously granted capability (immediate, forward-only)."""
        sid = self._require_session()
        return self.call(
            "noetic.revoke", {"sessionId": sid, "capabilityRef": capability_ref}
        )

    def request_access(
        self,
        space_id: str,
        rights: Sequence[str],
        *,
        persistence_mode: Optional[str] = None,
        reason: str = "",
    ) -> Dict[str, Any]:
        """Ask the owner of a remote space for scoped access (consumer side)."""
        sid = self._require_session()
        args: Dict[str, Any] = {
            "sessionId": sid,
            "space": space_id,
            # The server names this argument ``rights`` (not ``requestedRights``).
            "rights": list(rights),
        }
        if persistence_mode is not None:
            args["persistenceMode"] = persistence_mode
        if reason:
            args["reason"] = reason
        return self.call("noetic.request_access", args)

    def list_requests(self) -> List[Dict[str, Any]]:
        """List pending access requests on spaces you own (owner side)."""
        sid = self._require_session()
        data = self.call("noetic.list_requests", {"sessionId": sid})
        return data.get("requests") or []

    def approve_request(
        self,
        request_id: str,
        *,
        rights: Optional[Sequence[str]] = None,
        world_mutation: Optional[str] = None,
        persistence_mode: Optional[str] = None,
    ) -> GrantResult:
        """Approve a pending access request, minting the grant (owner side)."""
        sid = self._require_session()
        args: Dict[str, Any] = {"sessionId": sid, "requestId": request_id}
        if rights is not None:
            args["rights"] = list(rights)
        if world_mutation is not None:
            args["worldMutation"] = world_mutation
        if persistence_mode is not None:
            args["persistenceMode"] = persistence_mode
        data = self.call("noetic.approve_request", args)
        return self._grant_result(data)

    def deny_request(self, request_id: str) -> Dict[str, Any]:
        """Deny a pending access request (owner side)."""
        sid = self._require_session()
        return self.call(
            "noetic.deny_request", {"sessionId": sid, "requestId": request_id}
        )

    @staticmethod
    def _grant_result(data: Dict[str, Any]) -> GrantResult:
        return GrantResult(
            capability_ref=data.get("capabilityRef", ""),
            subject=data.get("subject", ""),
            resource=data.get("resource", ""),
            effective_rights=data.get("effectiveRights") or [],
            raw=data,
        )

    # -- discovery + introspection ---------------------------------------- #
    def discover(self, query: str = "", *, limit: int = 0) -> List[Dict[str, Any]]:
        """List publicly discoverable spaces (no session required)."""
        args: Dict[str, Any] = {}
        if query:
            args["query"] = query
        if limit:
            args["limit"] = limit
        data = self.call("noetic.discover", args)
        return data.get("spaces") or []

    def publish(self, space_id: str, *, visibility: str = "public") -> Dict[str, Any]:
        """Set a space's discovery visibility."""
        sid = self._require_session()
        return self.call(
            "noetic.publish",
            {"sessionId": sid, "space": space_id, "visibility": visibility},
        )

    def metrics(self) -> Dict[str, Any]:
        """Return scope/account/space usage metrics for the session."""
        sid = self._require_session()
        return self.call("noetic.metrics", {"sessionId": sid})
