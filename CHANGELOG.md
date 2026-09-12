# Changelog

All notable changes to the Priostack SDKs are documented here.

## [0.3.0] — 2026-09-12

### Added — quickstarts for the whole arc, not just the first step

Developers were reaching for the examples and stopping where the examples stopped: at `fetch`. Every
client now ships a **second** quickstart that goes all the way through a share.

- **Agent-framework quickstarts** — `examples/crewai_quickstart.py`, `examples/langgraph_quickstart.py`
  and `examples/autogen_quickstart.py`. Each gives every agent its own ACN identity and drives the
  full arc: register, create a space, store typed facts, grant scoped access to another agent, read
  across the grant. CrewAI binds ACN tools to each crew member's own client; the LangGraph example
  proves memory outlives the run by answering run 2 from what run 1 stored; the AutoGen example
  drives the pull model (discover, request, approve). Each runs on its own when the framework is
  not installed.
- **A sharing quickstart in every client language** (`share_quickstart`, 15 in all): two agents
  onboard separately, the owner stores, grants `read` + `quote`, the grantee reconnects and reads,
  then the grant is revoked. Each also shows what a space looks like *before* a grant — not empty,
  absent — because that is the part people assume wrong.
- `examples/mcp_config/README.md` gained **the first conversation to have with an MCP client**:
  connecting is not onboarding, and an agent that registers without creating a space has joined the
  network without using it.
- CI now syntax-checks the new JavaScript and shell examples, compiles the new C++ example, and
  runs `ruff` over `examples/`.

### Changed
- The Python client reads **`PRIOSTACK_ENDPOINT`** (the variable the other clients already used), so
  one export points every example at a local or self-hosted node.
- Every client is on **0.3.0**, including the user-agent each one sends. PHP, Dart and C++ had been
  left behind at `0.1.0`, and Kotlin's user agent still said `0.1.0` after its package version was
  corrected in 0.2.0.

### Fixed (documentation)
- Every `priostack.com/acn` link (5 client READMEs and the Python, PHP, Dart, Ruby and
  TypeScript package metadata) pointed at a 404. The Agent Context Network page lives at
  **https://priostack.com/agent-context-network**.
- The Swift and Rust packages named `github.com/priostack/priostack` — not this repository.
- Install instructions named packages that are published nowhere: `npm install @priostack/acn`
  (JavaScript, TypeScript), `gem install priostack` (Ruby), `composer require priostack/acn-client`
  (PHP), `com.priostack:priostack-acn` on Maven Central (Kotlin, Scala, Java) and a SwiftPM URL
  dependency that cannot resolve a package living in a repository subdirectory. Each now documents
  the install path that actually works from a checkout, and says plainly that the registry release
  is still to come. Python is unaffected: `pip install priostack` serves 0.2.0 from PyPI.
- Kotlin client version was `0.1.0` while every other client was `0.2.0`.

### Added
- `scripts/check-links.sh` — checks that relative Markdown links resolve to files and that no URL in
  the repository 404s. Runs as the `links` job in CI on every pull request.
- A **Documentation** table in the README linking the live ACN overview, tool reference, integration
  guides, developer hub, tutorials and the free-plan limits.

## [0.2.0] — 2026-09-10

### Fixed (Python client — the 0.1.1 client could not talk to the server)
- The client now **unwraps the MCP `result.content[0].text` envelope**. 0.1.1 returned the raw
  transport result, so every call handed back the wrong object.
- `register()` now returns the bearer token from `data.token`. 0.1.1 returned the entire envelope
  string as the "token".
- `connect()` now reads the session id from the **PascalCase** `data.SessionID` (the server
  serializes it with Go field names). 0.1.1 read `sessionId` and captured `None`, so every
  subsequent call failed.
- Tool-level denials (`ok:false`) now raise typed exceptions. 0.1.1 only checked for a top-level
  JSON-RPC `error` and silently swallowed capability/not-found/etc. failures.
- `grant` sends the space as `resource`; `request_access` sends `rights` — the argument names the
  server actually reads.

### Added
- Typed exception hierarchy (`ACNError`, `ACNTransportError`, `ACNToolError` + one subclass per
  outcome) in `priostack.exceptions`.
- Pooled `requests.Session` with conservative retries (connection + 429/503 only; reads never
  retried, so a `store` is never silently duplicated), per-request timeout, context-manager support.
- Full method coverage: `disconnect`, `rotate_token`, `capabilities`, `fetch`, `revoke_access`,
  `request_access`, `list_requests`, `approve_request`, `deny_request`, `discover`, `publish`,
  `metrics`, plus a generic `call()` escape hatch.
- Typed result objects (`RegisterResult`, `ConnectResult`, `SpaceResult`, `StoreResult`,
  `FetchResult`, `GrantResult`) and a `py.typed` marker.
- 25 unit tests over a mocked transport; new/fixed examples; MCP client configs for the canonical
  `/mcp` endpoint.
- **SDKs in 14 more languages** under `clients/` (JavaScript, TypeScript, Java, Go, C#, PHP, Ruby,
  Rust, Kotlin, Swift, C++, Dart, Scala, Shell), each with a quickstart and README.
- GitHub Actions CI: Python tests + a per-language build/type-check matrix on every pull request.

### Changed
- Default endpoint is now the canonical Streamable-HTTP MCP endpoint `https://priostack.com/mcp`
  (`/acn/rpc` remains a working alias).
- README rewritten for accuracy (correct wire shapes, method signatures, and MCP client setup).
- Added `.gitignore`; stopped tracking generated bytecode and build artifacts.

## [0.1.1]
- Initial public release.
