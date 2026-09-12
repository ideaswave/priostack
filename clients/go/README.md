# Priostack ACN — Go client

Official Go SDK for the [Priostack Agent Context Network (ACN)](https://priostack.com/agent-context-network):
model-agnostic, zero-setup long-term memory and multi-agent context sharing for AI agents,
over the Model Context Protocol (MCP).

The client speaks the ACN JSON-RPC 2.0 wire contract directly — it unwraps the MCP
`result.content[0].text` tool envelope, returns typed errors on tool denials, reuses one
`*http.Client`, and captures the bearer token and session id for you. Standard library only,
no third-party dependencies.

## Install

```bash
go get github.com/ideaswave/priostack/clients/go
```

Requires Go 1.22+. Import it as `priostack`:

```go
import priostack "github.com/ideaswave/priostack/clients/go"
```

## Usage

```go
client := priostack.New()
defer client.Close()

client.Register("my-agent")                              // token captured internally
client.Connect("", 0)                                    // session id captured internally
space, _ := client.CreateSpace("prod-memory", nil)
client.Store(space.SpaceID, []priostack.StoreObject{{Content: "Refunds over $500 need approval.", Type: "declaration"}})
hits, _ := client.Fetch(space.SpaceID, "refund", 0)
fmt.Println(hits.Contents())                             // ["Refunds over $500 need approval."]
```

(Handle the returned `error` from each call in real code — omitted above for brevity.)

## Run the quickstart

The `example/quickstart` command runs register → connect → create space → store → fetch
against the live endpoint and prints each step:

```bash
go run ./example/quickstart                 # display name defaults to "go-sdk-smoke"
go run ./example/quickstart my-agent-name   # or pass your own
```

Override the endpoint (default `https://priostack.com/mcp`, alias `/acn/rpc`) with
`PRIOSTACK_ENDPOINT`.

## Errors

Two error kinds are returned, both satisfying the `priostack.Error` interface:

- **`*TransportError`** — a network, HTTP, decoding, or JSON-RPC protocol failure (no valid
  tool envelope was obtained).
- **`*ToolError`** — the tool ran but declined the call (envelope `ok=false`). It carries the
  server `Outcome` and `Detail`, and unwraps to a sentinel so you can match a specific denial:

```go
_, err := client.Store(space.SpaceID, objects)
switch {
case errors.Is(err, priostack.ErrCapabilityDenied):
    // the session lacks the write right / mutate capability
case errors.Is(err, priostack.ErrNotFound):
    // no such session or space
}

if te, ok := priostack.AsToolError(err); ok {
    log.Printf("outcome=%s detail=%s", te.Outcome, te.Detail)
}
```

Sentinels: `ErrNotFound`, `ErrInvalidQuery`, `ErrCapabilityDenied`, `ErrPolicyDenied`,
`ErrRequiresGovernance`, `ErrStaleBase`, `ErrIntegrityFault`, `ErrConflict`,
`ErrCapacityExhausted`, `ErrNotSupported`.

## API surface

| Go method | Tool |
| :-- | :-- |
| `Register(displayName)` | `noetic.register` |
| `Connect(token, maxTokens)` | `noetic.connect` |
| `CreateSpace(displayName, opts)` | `noetic.create_space` |
| `Store(spaceID, objects)` | `noetic.store` |
| `Fetch(spaceID, query, limit)` | `noetic.fetch` |
| `GrantAccess(spaceID, subjectPrincipal, opts)` | `noetic.grant` |
| `RevokeAccess(capabilityRef)` | `noetic.revoke` |
| `RequestAccess(spaceID, rights, opts)` | `noetic.request_access` |
| `ListRequests()` / `ApproveRequest(id, opts)` / `DenyRequest(id)` | `noetic.list_requests` / `noetic.approve_request` / `noetic.deny_request` |
| `Discover(query, limit)` / `Publish(spaceID, visibility)` | `noetic.discover` / `noetic.publish` |
| `Capabilities()` / `Metrics()` / `RotateToken()` / `Disconnect()` | `noetic.*` |
| `Call(method, arguments)` | any `noetic.*` tool (escape hatch) |

`Call` is the low-level escape hatch behind every typed method; use it to reach tools this
client does not wrap explicitly.

## Share a space with another agent

[`example/share/main.go`](example/share/main.go) is the other half of the quickstart: two agents register separately, the owner stores
knowledge and grants the second agent scoped `read` + `quote` on one space, the grantee reconnects
and reads it — and a revoke takes it away again. It also shows what a space looks like *before* a
grant: not empty, absent.

```bash
go run ./example/share
```

Point any example at a self-hosted or local node with `PRIOSTACK_ENDPOINT`.

## License

MIT. See the repository `LICENSE`.
