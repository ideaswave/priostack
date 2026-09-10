# ⚡ Priostack Agent Context Network (ACN)

> **Zero-setup, model-agnostic long-term memory and multi-agent context sharing over MCP.**

[![PyPI version](https://img.shields.io/pypi/v/priostack.svg)](https://pypi.org/project/priostack/)
[![CI](https://github.com/ideaswave/priostack/actions/workflows/ci.yml/badge.svg)](https://github.com/ideaswave/priostack/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Priostack ACN treats an agent's long-term memory as a **network resource** instead of something
bolted to one LLM vendor. It is a **Model Context Protocol (MCP)** server, reached over JSON-RPC 2.0,
where agents self-register, keep isolated context spaces, store typed facts, read them back, and share
them with other agents through scoped, revocable capability grants.

The public server is live at **`https://priostack.com/mcp`** (a discoverable Streamable-HTTP MCP
endpoint; `https://priostack.com/acn/rpc` is a working alias).

---

## 🔥 What it gives you

- 🤖 **Zero-setup onboarding** — an agent self-registers via `noetic.register` and gets a bearer
  token. No dashboard, no UI, no credit card.
- 🌐 **Model-agnostic memory** — the same context serves an OpenAI, Anthropic, or local-model agent;
  memory is decoupled from the model.
- 🤝 **Scoped multi-agent sharing** — grant another agent explicit content rights (`read`, `quote`,
  `write`, `share`, `export`, ...) on a space, or let it `request_access` and approve it. Grants are
  revocable and forward-only.
- 🧠 **Typed facts** — store `declaration`s (rules/policies), `observation`s (measured facts), and
  `measurement`s, keeping "what is asserted" separate from "what was observed".
- 🔌 **Native MCP** — connect Claude Desktop, Cursor, or any MCP client by URL, or use one of the
  SDKs below.

---

## 🚀 Quickstart (Python)

```bash
pip install priostack
```

```python
from priostack import ACNClient

with ACNClient() as acn:                       # defaults to https://priostack.com/mcp
    acn.register(display_name="my-agent")      # self-register; token captured on the client
    acn.connect()                              # open a session; session id captured internally

    space = acn.create_space(display_name="prod-memory")
    acn.store(space.space_id, objects=[
        {"content": "Refunds over $500 require manager approval.", "type": "declaration"},
        {"content": "Export pipeline latency was 1.8s at 14:02 UTC.", "type": "observation"},
    ])

    hits = acn.fetch(space.space_id, query="refund")   # substring content reader
    for content in hits.contents():
        print(content)
```

> **Persist the token.** `register()` returns a bearer token that is shown once. Store it (and the
> space id) and reconnect later with `ACNClient(token=...)` instead of registering again.

More runnable examples in [`examples/`](examples/): [multi-agent sharing](examples/context_sharing.py),
[request &amp; approve access](examples/request_and_approve.py),
[fetch &amp; recall](examples/fetch_and_recall.py),
[revoke &amp; rotate](examples/revoke_and_rotate.py), and memory integrations for
[LangChain](examples/langchain_memory.py), [CrewAI](examples/crewai_memory.py), and a
[Claude agent](examples/claude_agent_memory.py).

---

## 🤝 Multi-agent context sharing

An owner grants another agent scoped access to a space. The grant subject is the grantee's **agent
id** (returned by `register()`), and the grantee must **reconnect** afterward to pick up the widened
scope.

```python
# Owner stores knowledge and grants read + quote to a worker agent.
grant = owner.grant_access(space.space_id, worker_agent_id, rights=["read", "quote"])

worker.connect()                       # reconnect to apply the grant
print(worker.fetch(space.space_id, query="refund").contents())

owner.revoke_access(grant.capability_ref)   # immediate, forward-only
```

Prefer a pull model? The consumer calls `request_access(space_id, rights=["read"])`, the owner
`list_requests()` and `approve_request(request_id)`. See
[`examples/request_and_approve.py`](examples/request_and_approve.py).

---

## 🌍 SDKs in 15 languages

Python is the reference SDK (this repo root, on PyPI). Idiomatic clients for 14 more languages live
under [`clients/`](clients/), each with its own quickstart and README and each implementing the exact
same wire contract ([`clients/SPEC.md`](clients/SPEC.md)).

| Language | Path | HTTP + JSON stack |
| :--- | :--- | :--- |
| Python | [`/`](src/priostack) · PyPI `priostack` | `requests` |
| JavaScript (Node ≥20) | [`clients/javascript`](clients/javascript) | built-in `fetch` |
| TypeScript | [`clients/typescript`](clients/typescript) | global `fetch` (typed) |
| Java (Maven) | [`clients/java`](clients/java) | `java.net.http` + Jackson |
| Go | [`clients/go`](clients/go) | stdlib `net/http` |
| C# / .NET 8 | [`clients/csharp`](clients/csharp) | `HttpClient` + `System.Text.Json` |
| PHP (Composer) | [`clients/php`](clients/php) | curl |
| Ruby | [`clients/ruby`](clients/ruby) | stdlib `net/http` |
| Rust | [`clients/rust`](clients/rust) | `reqwest` + `serde` |
| Kotlin (Gradle) | [`clients/kotlin`](clients/kotlin) | `java.net.http` |
| Swift (SwiftPM) | [`clients/swift`](clients/swift) | `URLSession` + `Codable` |
| C++17 | [`clients/cpp`](clients/cpp) | libcurl + nlohmann/json |
| Dart | [`clients/dart`](clients/dart) | `package:http` |
| Scala | [`clients/scala`](clients/scala) | `java.net.http` + uPickle |
| Shell | [`clients/shell`](clients/shell) | `curl` + `jq` |

Each client unwraps the MCP envelope, captures the session id, raises typed errors on tool denials,
and reuses one HTTP connection. The Python, JavaScript, TypeScript, Java, Ruby, and C++ clients have
been run end-to-end against the live server; the rest are verified against the contract and build in
CI (see [`.github/workflows/ci.yml`](.github/workflows/ci.yml)).

---

## 🛠️ Use it from an MCP client (Claude Desktop, Cursor)

The ACN is a discoverable Streamable-HTTP MCP server, so an MCP client connects by URL. Ready-made
configs are in [`examples/mcp_config/`](examples/mcp_config/).

**Claude Desktop** (Settings → Developer → Edit Config), via the `mcp-remote` bridge:

```json
{
  "mcpServers": {
    "priostack-acn": { "command": "npx", "args": ["-y", "mcp-remote", "https://priostack.com/mcp"] }
  }
}
```

**Cursor** (native remote MCP by URL):

```json
{ "mcpServers": { "priostack-acn": { "url": "https://priostack.com/mcp" } } }
```

Sanity-check discovery yourself:

```bash
curl -s https://priostack.com/mcp -H 'Content-Type: application/json' -H 'Accept: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | jq '.result.tools | length'
```

---

## 📖 API reference (JSON-RPC 2.0)

Endpoint: `https://priostack.com/mcp` (alias `https://priostack.com/acn/rpc`).

Every call is a `tools/call`:

```json
{"jsonrpc":"2.0","id":1,"method":"tools/call",
 "params":{"name":"noetic.store","arguments":{ "sessionId":"...", "space":"space-1", "objects":[...] }}}
```

The response wraps the result envelope as text; unwrap it as
`JSON.parse(response.result.content[0].text)` to get `{ok, outcome, data, detail?}`. On `ok:false`
the `outcome` is one of `not-found`, `invalid-query`, `capability-denied`, `policy-denied`,
`requires-governance`, `stale-base`, `integrity-fault`, `conflict`, `capacity-exhausted`,
`not-implemented`. (Every SDK above does this unwrapping and error mapping for you.)

| Method | Purpose | Key arguments | Notes |
| :--- | :--- | :--- | :--- |
| `noetic.register` | Self-register an agent | `displayName` | returns `data.token` (shown once) |
| `noetic.connect` | Open a session | `token`, `maxResponseTokens` | returns `data.SessionID` (**PascalCase**) |
| `noetic.create_space` | Create a context space | `sessionId`, `displayName`, `defaultRights` | returns `data.spaceId` |
| `noetic.store` | Persist typed facts | `sessionId`, `space`, `objects[]` | `type` ∈ declaration \| observation \| measurement |
| `noetic.fetch` | **Read stored content back** | `sessionId`, `space`, `query`, `limit` | substring filter; this is the reader |
| `noetic.grant` | Grant scoped access | `sessionId`, `subjectPrincipal`, `resource`, `rights[]`, `worldMutation` | space arg is `resource`; grantee reconnects |
| `noetic.revoke` | Revoke a capability | `sessionId`, `capabilityRef` | immediate, forward-only |
| `noetic.request_access` | Ask for access | `sessionId`, `space`, `rights[]`, `reason` | rights arg is `rights` |
| `noetic.list_requests` | List pending requests | `sessionId` | owner side |
| `noetic.approve_request` | Approve a request | `sessionId`, `requestId`, `rights[]` | mints the grant |
| `noetic.discover` | List public spaces | `query`, `limit` | no session required |
| `noetic.metrics` | Usage for the session | `sessionId` | account + space gauges |
| `noetic.rotate_token` | Mint a fresh token | `sessionId` | retires the old token |
| `noetic.disconnect` | End the session | `sessionId` | durable facts are kept |

> **`fetch` vs `query`:** `noetic.fetch` returns stored **content** (substring-filtered). `noetic.query`
> is a *geometric* divergence probe over the memory, not a content read — don't reach for it to read
> facts back.

There are ~40 tools in total; every SDK exposes a generic `call(method, arguments)` escape hatch to
reach the ones not wrapped explicitly.

---

## 📚 Documentation

| | |
|---|---|
| [What the Agent Context Network is](https://priostack.com/agent-context-network) | The concept, the permission model, FAQ |
| [API & tools reference](https://priostack.com/docs-agent-context-network) | Every MCP tool, grouped by what it does |
| [Integration guides](https://priostack.com/integrations) | Claude, Cursor, LangChain, CrewAI, OpenAI-compatible agents |
| [Developer hub](https://priostack.com/developers) | MCP, Python and HTTP entry points |
| [Tutorials](https://priostack.com/tutorials) | Step-by-step walkthroughs |
| [Free plan and limits](https://priostack.com/pricing) | Free to use: 5 spaces, 500,000 objects and 500,000 queries a month per agent account |

---

## 🧪 Development

```bash
pip install -e ".[dev]"
pytest                     # unit tests (mocked transport, no network)
ruff check src tests
./scripts/check-links.sh   # every link in the docs still resolves
```

CI (GitHub Actions) runs the Python test suite, builds/type-checks every language client, and
checks the documentation links on each pull request.

---

## 📄 License

MIT. See [`LICENSE`](LICENSE).
