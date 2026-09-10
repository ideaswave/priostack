"""Shared test fixtures: an in-memory fake transport for ACNClient.

No test in this suite touches the network. A :class:`MockSession` is injected
into :class:`priostack.ACNClient` (which then skips its retry configuration and
uses the injected session verbatim), letting each test script the exact JSON
the server would return and assert on the exact JSON the client sent.
"""

from __future__ import annotations

import json
from typing import Any, Dict, List, Optional

import pytest


class MockResponse:
    def __init__(self, status_code: int, body: Any):
        self.status_code = status_code
        if isinstance(body, (dict, list)):
            self._text = json.dumps(body)
            self._json = body
        else:
            self._text = str(body)
            self._json = None

    @property
    def text(self) -> str:
        return self._text

    def json(self) -> Any:
        if self._json is None:
            raise ValueError("no json")
        return self._json


class MockSession:
    """Stands in for requests.Session. Scripts responses, records requests."""

    def __init__(self) -> None:
        self.headers: Dict[str, str] = {}
        self.sent: List[Dict[str, Any]] = []
        self._scripted: List[MockResponse] = []
        self._default: Optional[MockResponse] = None
        self.closed = False

    # -- scripting helpers ------------------------------------------------- #
    def envelope(self, ok: bool, *, outcome: str = "ok", data: Any = None,
                 detail: str = "", rpc_id: int = 1, is_error: Optional[bool] = None):
        """Queue a well-formed MCP envelope response."""
        env: Dict[str, Any] = {"ok": ok, "outcome": outcome}
        if data is not None:
            env["data"] = data
        if detail:
            env["detail"] = detail
        body = {
            "jsonrpc": "2.0",
            "id": rpc_id,
            "result": {
                "content": [{"type": "text", "text": json.dumps(env)}],
                "isError": (not ok) if is_error is None else is_error,
            },
        }
        self._scripted.append(MockResponse(200, body))
        return self

    def raw(self, status_code: int, body: Any):
        """Queue an arbitrary raw response (for transport-error tests)."""
        self._scripted.append(MockResponse(status_code, body))
        return self

    def always_ok(self, data: Any = None):
        """Every unscripted call returns ok with this data (for id/retry tests)."""
        env = {"ok": True, "outcome": "ok", "data": data or {}}
        body = {
            "jsonrpc": "2.0",
            "id": 0,
            "result": {"content": [{"type": "text", "text": json.dumps(env)}], "isError": False},
        }
        self._default = MockResponse(200, body)
        return self

    # -- requests.Session surface ----------------------------------------- #
    def post(self, url, json=None, timeout=None):  # noqa: A002 - mirror requests API
        self.sent.append(json)
        if self._scripted:
            return self._scripted.pop(0)
        if self._default is not None:
            return self._default
        raise AssertionError("MockSession got an unscripted request")

    def mount(self, prefix, adapter):  # pragma: no cover - unused with injection
        pass

    def close(self):
        self.closed = True

    # -- assertions -------------------------------------------------------- #
    def last_args(self) -> Dict[str, Any]:
        return self.sent[-1]["params"]["arguments"]

    def last_method(self) -> str:
        return self.sent[-1]["params"]["name"]


@pytest.fixture
def mock():
    return MockSession()


@pytest.fixture
def client(mock):
    from priostack import ACNClient

    return ACNClient(session=mock)
