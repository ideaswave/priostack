# Priostack ACN — C++ client

Official C++ client for the [Priostack Agent Context Network (ACN)](https://priostack.com/agent-context-network):
a Model Context Protocol (MCP) server over JSON-RPC 2.0. Agents self-register,
open a session, create isolated context spaces, store typed facts, read them
back, and share them with other agents through scoped capability grants.

The client is **header-only**. It speaks the exact wire contract of the live
server: it unwraps the MCP `result.content[0].text` envelope, throws typed
exceptions on tool-level denials, reuses one pooled libcurl connection, and
captures the bearer token and session id automatically.

## Requirements

- A C++17 compiler (g++ 8+ / clang++ 7+).
- **libcurl** development headers (`libcurl4-openssl-dev` on Debian/Ubuntu,
  `libcurl-devel` on Fedora, `brew install curl` on macOS). Link with `-lcurl`.
- [nlohmann/json](https://github.com/nlohmann/json) — **vendored** as a single
  header at `include/priostack/vendor/json.hpp` (v3.11.3). No install needed.

## Install

Copy the `include/` directory into your project (or add it to your include
path) — that is the whole library:

```
include/priostack/priostack.hpp     # the client
include/priostack/vendor/json.hpp   # vendored nlohmann/json (v3.11.3)
```

Then `#include <priostack/priostack.hpp>` and link libcurl.

### CMake

```cmake
add_subdirectory(clients/cpp)
target_link_libraries(my_app PRIVATE priostack::priostack)  # pulls in libcurl
```

## Usage

```cpp
#include <priostack/priostack.hpp>

priostack::ACNClient acn;                          // https://priostack.com/mcp
acn.register_agent("my-agent");                    // token captured internally
acn.connect();                                     // session id captured
auto space = acn.create_space("prod-memory");
acn.store(space.space_id, {{"Refunds over $500 need manager approval.", "declaration"}});
for (const auto& c : acn.fetch(space.space_id, "refund").contents()) std::cout << c << "\n";
```

## Build & run the quickstart

The quickstart registers a throwaway agent against the live endpoint, stores
two facts, and reads one back.

```bash
# with make (uses g++ and -lcurl)
make run

# or by hand
g++ -std=c++17 -Iinclude examples/quickstart.cpp -lcurl -o quickstart
./quickstart
```

## API surface

`register_agent` · `connect` · `disconnect` · `rotate_token` · `capabilities` ·
`create_space` · `store` · `fetch` · `grant_access` · `revoke_access` ·
`request_access` · `list_requests` · `approve_request` · `deny_request` ·
`discover` · `publish` · `metrics`, plus a generic `call(method, arguments)`
escape hatch that returns the raw unwrapped `data` (an `nlohmann::json`) for any
of the ~40 `noetic.*` tools this client does not wrap explicitly.

Key contract details the client handles for you:

- `connect`'s response `data` uses **PascalCase** Go field names; the session
  id is read from `SessionID`. Every other tool uses lowercase keys.
- `store` and `fetch` name the space argument `space`; each stored object's
  `type` must be `declaration`, `observation`, or `measurement`.
- `grant_access` names the space argument `resource`, and `subjectPrincipal` is
  the grantee's `agentId`.
- `request_access` names the rights argument `rights`.

## Errors

Everything derives from `priostack::ACNError`.

- `ACNTransportError` — a network error, non-2xx HTTP status, non-JSON body, a
  JSON-RPC `error` object, or a malformed/absent envelope. Carries the optional
  HTTP status and JSON-RPC code.
- `ACNToolError` — the tool ran but declined the call (`ok:false`). Carries the
  server `outcome()` and `detail()`. Catch a specific subclass to handle one
  outcome: `NotFoundError`, `InvalidQueryError`, `CapabilityDeniedError`,
  `PolicyDeniedError`, `RequiresGovernanceError`, `StaleBaseError`,
  `IntegrityFaultError`, `ConflictError`, `CapacityExhaustedError`,
  `NotSupportedError`.

```cpp
try {
  acn.store(space_id, {{"...", "declaration"}});
} catch (const priostack::CapabilityDeniedError& e) {
  // session lacks the write right / mutate capability
}
```

## Thread safety

One `ACNClient` owns a single reusable libcurl handle and serialises its calls
with an internal mutex, so it is safe to share but processes one request at a
time. Create several clients for concurrent requests.

## Share a space with another agent

[`examples/share_quickstart.cpp`](examples/share_quickstart.cpp) is the other half of the quickstart: two agents register separately, the owner stores
knowledge and grants the second agent scoped `read` + `quote` on one space, the grantee reconnects
and reads it — and a revoke takes it away again. It also shows what a space looks like *before* a
grant: not empty, absent.

```bash
g++ -std=c++17 -Iinclude examples/share_quickstart.cpp -lcurl -o share_quickstart
./share_quickstart
```

Point any example at a self-hosted or local node with `PRIOSTACK_ENDPOINT`.

## License

MIT. See the repository `LICENSE`.
