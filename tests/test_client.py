"""Unit tests for ACNClient against a mocked transport.

These assert the client matches the real ACN wire contract (see the repo's
verified contract): envelope unwrapping, PascalCase connect keys, correct
argument names, typed error mapping, and transport-fault handling.
"""

from __future__ import annotations

import pytest

from priostack import (
    DEFAULT_ENDPOINT,
    ENDPOINT_ENV_VAR,
    ACNClient,
    ACNToolError,
    ACNTransportError,
    CapabilityDeniedError,
    NotFoundError,
    NotSupportedError,
)


# --- identity ------------------------------------------------------------- #
def test_register_captures_token(client, mock):
    mock.envelope(True, data={"token": "acn_abc", "agentId": "agent-1",
                              "accountId": "acct-1", "tier": "Growth"})
    res = client.register(display_name="primary")
    assert res.token == "acn_abc"
    assert res.agent_id == "agent-1"
    assert client.token == "acn_abc"
    assert mock.last_method() == "noetic.register"
    assert mock.last_args() == {"displayName": "primary"}


def test_register_unavailable_maps_to_not_supported(client, mock):
    mock.envelope(False, outcome="not-implemented",
                  detail="registration is only available on the online ACN")
    with pytest.raises(NotSupportedError) as ei:
        client.register()
    assert ei.value.outcome == "not-implemented"


def test_connect_reads_pascalcase_and_captures_session(client, mock):
    mock.envelope(True, data={
        "SessionID": "sess-xyz", "ResolvedAccount": "acct-1",
        "GrantedCapabilities": ["read", "mutate", "owner"],
        "GrantedContextRights": None, "BoundSpace": "space-1",
        "ResolvedMaxTokens": 4096,
    })
    res = client.connect(token="acn_abc")
    assert res.session_id == "sess-xyz"
    assert client.session_id == "sess-xyz"
    assert res.resolved_account == "acct-1"
    assert res.granted_capabilities == ["read", "mutate", "owner"]
    assert res.granted_context_rights == []  # None normalized to []
    assert res.bound_space == "space-1"
    assert mock.last_args() == {"token": "acn_abc", "maxResponseTokens": 4096}


def test_connect_without_token_raises(client):
    # No token registered or passed → cannot connect.
    with pytest.raises(ACNTransportError):
        client.connect()


def test_connect_missing_session_id_raises(client, mock):
    mock.envelope(True, data={"ResolvedAccount": "acct-1"})  # no SessionID
    with pytest.raises(ACNTransportError):
        client.connect(token="acn_abc")


# --- spaces + facts ------------------------------------------------------- #
def _connected(client, mock):
    mock.envelope(True, data={"SessionID": "sess-1", "ResolvedMaxTokens": 4096})
    client.connect(token="t")
    return client


def test_create_space(client, mock):
    _connected(client, mock)
    mock.envelope(True, data={"spaceId": "space-9", "accountId": "acct-1",
                              "persistenceMode": "private_memory",
                              "protectionLevel": "open"})
    sp = client.create_space("prod-memory", default_rights=["read", "quote"])
    assert sp.space_id == "space-9"
    assert sp.persistence_mode == "private_memory"
    args = mock.last_args()
    assert args["displayName"] == "prod-memory"
    assert args["defaultRights"] == ["read", "quote"]
    assert args["sessionId"] == "sess-1"


def test_store_normalizes_and_counts(client, mock):
    _connected(client, mock)
    mock.envelope(True, data={"objectRefs": [{"objectRef": "obj-1"},
                                             {"objectRef": "obj-2"}]})
    res = client.store("space-9", objects=[
        {"content": "rule A", "type": "declaration"},
        {"content": "obs B", "type": "observation", "provenance": ["src"]},
    ])
    assert res.count == 2
    args = mock.last_args()
    assert args["space"] == "space-9"
    assert args["objects"][0] == {"content": "rule A", "type": "declaration"}
    assert args["objects"][1]["provenance"] == ["src"]


def test_store_rejects_bad_type(client, mock):
    _connected(client, mock)
    with pytest.raises(ValueError):
        client.store("space-9", objects=[{"content": "x", "type": "hypothesis"}])


def test_store_rejects_missing_content(client, mock):
    _connected(client, mock)
    with pytest.raises(ValueError):
        client.store("space-9", objects=[{"type": "declaration"}])


def test_fetch_maps_result(client, mock):
    _connected(client, mock)
    mock.envelope(True, data={
        "space": "space-9",
        "objects": [{"objectRef": "obj-1", "kind": "declaration",
                     "content": "rule A", "tokens": 3}],
        "matched": 1, "total": 5, "returnedTokens": 3,
    })
    res = client.fetch("space-9", query="rule", limit=10)
    assert res.matched == 1 and res.total == 5
    assert res.contents() == ["rule A"]
    args = mock.last_args()
    assert args["query"] == "rule" and args["limit"] == 10


# --- sharing -------------------------------------------------------------- #
def test_grant_uses_resource_arg(client, mock):
    _connected(client, mock)
    mock.envelope(True, data={"capabilityRef": "cap-1", "subject": "agent-2",
                              "resource": "space-9",
                              "effectiveRights": ["read", "quote"]})
    g = client.grant_access("space-9", "agent-2", rights=["read", "quote"])
    assert g.capability_ref == "cap-1"
    args = mock.last_args()
    assert args["resource"] == "space-9"       # the real server field name
    assert args["subjectPrincipal"] == "agent-2"
    assert args["rights"] == ["read", "quote"]
    assert "worldMutation" not in args          # omitted so server derives it


def test_request_access_uses_rights_arg(client, mock):
    _connected(client, mock)
    mock.envelope(True, data={"requestId": "req-1"})
    client.request_access("space-9", rights=["read"], reason="need it")
    args = mock.last_args()
    assert args["rights"] == ["read"]           # NOT requestedRights
    assert args["reason"] == "need it"


def test_revoke(client, mock):
    _connected(client, mock)
    mock.envelope(True, data={"ok": True, "capabilityRef": "cap-1"})
    client.revoke_access("cap-1")
    assert mock.last_args() == {"sessionId": "sess-1", "capabilityRef": "cap-1"}


# --- error + transport handling ------------------------------------------ #
def test_tool_denial_maps_to_typed_error(client, mock):
    _connected(client, mock)
    mock.envelope(False, outcome="capability-denied", detail="no write right")
    with pytest.raises(CapabilityDeniedError) as ei:
        client.store("space-9", objects=[{"content": "x", "type": "declaration"}])
    assert ei.value.detail == "no write right"
    assert ei.value.method == "noetic.store"


def test_not_found_maps(client, mock):
    _connected(client, mock)
    mock.envelope(False, outcome="not-found", detail="no such session")
    with pytest.raises(NotFoundError):
        client.fetch("space-9")


def test_unknown_outcome_falls_back_to_base(client, mock):
    _connected(client, mock)
    mock.envelope(False, outcome="brand-new-outcome", detail="???")
    with pytest.raises(ACNToolError) as ei:
        client.metrics()
    assert type(ei.value) is ACNToolError
    assert ei.value.outcome == "brand-new-outcome"


def test_partial_data_attached_to_error(client, mock):
    _connected(client, mock)
    mock.envelope(False, outcome="capacity-exhausted", detail="cap",
                  data={"stored": [{"objectRef": "obj-1"}]})
    with pytest.raises(ACNToolError) as ei:
        client.store("space-9", objects=[{"content": "x", "type": "declaration"}])
    assert ei.value.data == {"stored": [{"objectRef": "obj-1"}]}


def test_jsonrpc_error_is_transport(client, mock):
    _connected(client, mock)
    mock.raw(200, {"jsonrpc": "2.0", "id": 1,
                   "error": {"code": -32601, "message": "method not found"}})
    with pytest.raises(ACNTransportError) as ei:
        client.call("noetic.bogus", {})
    assert ei.value.code == -32601


def test_http_error_is_transport(client, mock):
    _connected(client, mock)
    mock.raw(500, "internal error")
    with pytest.raises(ACNTransportError) as ei:
        client.metrics()
    assert ei.value.http_status == 500


def test_non_json_body_is_transport(client, mock):
    _connected(client, mock)
    mock.raw(200, "<html>gateway</html>")
    with pytest.raises(ACNTransportError):
        client.metrics()


def test_missing_content_block_is_transport(client, mock):
    _connected(client, mock)
    mock.raw(200, {"jsonrpc": "2.0", "id": 1, "result": {"isError": False}})
    with pytest.raises(ACNTransportError):
        client.metrics()


def test_require_session_guard(client):
    with pytest.raises(ACNTransportError):
        client.create_space("x")


# --- protocol plumbing ---------------------------------------------------- #
def test_ids_increment_and_envelope_shape(client, mock):
    mock.always_ok({"SessionID": "s"})
    client.call("noetic.a", {})
    client.call("noetic.b", {})
    assert mock.sent[0]["id"] == 1
    assert mock.sent[1]["id"] == 2
    assert mock.sent[0]["jsonrpc"] == "2.0"
    assert mock.sent[0]["method"] == "tools/call"
    assert mock.sent[0]["params"]["name"] == "noetic.a"


def test_context_manager_disconnects(mock):
    mock.envelope(True, data={"SessionID": "sess-1", "ResolvedMaxTokens": 4096})
    with ACNClient(session=mock) as c:
        c.connect(token="t")
        mock.envelope(True, data={})  # for disconnect on exit
    assert c.session_id is None       # disconnect cleared it


def test_retry_policy_never_retries_reads():
    """Real (non-injected) session must be configured read=0 to avoid double-writes."""
    c = ACNClient()
    adapter = c._http.get_adapter("https://priostack.com/mcp")
    retry = adapter.max_retries
    assert retry.read == 0
    assert 429 in retry.status_forcelist and 503 in retry.status_forcelist
    c.close()


def test_endpoint_defaults_to_canonical_mcp_url(mock):
    assert ACNClient(session=mock).endpoint == DEFAULT_ENDPOINT


def test_endpoint_reads_the_environment(mock, monkeypatch):
    """Every example in this repository follows one exported variable, unedited."""
    monkeypatch.setenv(ENDPOINT_ENV_VAR, "http://127.0.0.1:8091/rpc")
    assert ACNClient(session=mock).endpoint == "http://127.0.0.1:8091/rpc"


def test_explicit_endpoint_beats_the_environment(mock, monkeypatch):
    monkeypatch.setenv(ENDPOINT_ENV_VAR, "http://127.0.0.1:8091/rpc")
    assert ACNClient("https://acn.example.com/mcp", session=mock).endpoint == "https://acn.example.com/mcp"
