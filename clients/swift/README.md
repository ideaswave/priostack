# Priostack ACN — Swift client

Official Swift client for the [Priostack Agent Context Network (ACN)](https://priostack.com/agent-context-network):
zero-setup, model-agnostic long-term memory and multi-agent context sharing for
AI agents, over the Model Context Protocol (MCP).

Pure Foundation — `URLSession` + `Codable` + `async`/`await`. No third-party
dependencies.

## Requirements

- Swift 5.9+ on Apple platforms (macOS 12+, iOS 15+).
- **Swift 5.10+ on Linux**: the client uses `URLSession.data(for:)`, which swift-corelibs-foundation
  only gained later than Darwin — on a 5.9 Linux toolchain the build fails with
  `value of type 'URLSession' has no member 'data'`.

## Install

The client lives in a subdirectory of this repository, and SwiftPM cannot fetch
a package from a subdirectory by URL, so depend on a local checkout:

```bash
git clone https://github.com/ideaswave/priostack.git
```

```swift
dependencies: [
    .package(path: "../priostack/clients/swift"),
],
targets: [
    .target(
        name: "YourApp",
        dependencies: [.product(name: "PriostackACN", package: "PriostackACN")]
    ),
]
```

Or, in Xcode: *File ▸ Add Package Dependencies… ▸ Add Local…* and point it at
`clients/swift`, then add the **PriostackACN** library product to your target.

## Usage

```swift
import PriostackACN

let acn = ACNClient()                                   // defaults to https://priostack.com/mcp
try await acn.register(displayName: "my-agent")         // bearer token captured internally
try await acn.connect()                                 // session id captured internally
let space = try await acn.createSpace(displayName: "prod-memory")
try await acn.store(space: space.spaceId, objects: [
    ContextObject(content: "Refunds over $500 need manager approval.", type: .declaration),
])
let hits = try await acn.fetch(space: space.spaceId, query: "refund")
hits.contents.forEach { print($0) }                     // -> "Refunds over $500 need manager approval."
```

`ACNClient` is an `actor`, so one instance is safe to share across concurrent
tasks; it reuses a single pooled `URLSession`, applies a ~30s timeout, and
increments the JSON-RPC id per call.

### Errors

Every call throws a typed `ACNError`:

- `ACNToolError` — the tool declined the call (`ok: false`); carries `outcome`
  (an `ACNOutcome`, e.g. `.capabilityDenied`, `.notFound`) and `detail`.
- `ACNTransportError` — a network, HTTP, JSON-RPC, or decoding failure.

```swift
do {
    try await acn.store(space: spaceId, objects: [ContextObject(content: "...")])
} catch let error as ACNToolError where error.outcome == .capabilityDenied {
    // the session lacks the write right / mutate capability
} catch let error as ACNError {
    print("ACN call failed: \(error.message)")
}
```

Tools without a typed wrapper (there are ~40) are reachable through the escape
hatch, which returns the envelope's `data` as a `JSONValue`:

```swift
let data = try await acn.call("noetic.metrics", arguments: ["sessionId": .string(sessionId)])
print(data["spaces"]?.intValue ?? 0)
```

## Quickstart example

The bundled `quickstart` executable runs register → connect → createSpace →
store → fetch against the live endpoint:

```bash
swift run quickstart              # display name defaults to "swift-sdk-smoke"
swift run quickstart my-agent     # or pass your own
ACN_ENDPOINT=https://priostack.com/acn/rpc swift run quickstart   # override endpoint
```

## Build & test

```bash
swift build          # compile the library + quickstart
```

## Wire contract notes

- Requests are JSON-RPC 2.0 `tools/call`; the result is unwrapped from
  `result.content[0].text`, which is itself a JSON string holding the
  `{ok, outcome, data, detail}` envelope.
- `connect`'s `data` uses **PascalCase** Go field names (`SessionID`,
  `ResolvedAccount`, …), mapped by `CodingKeys` in `ConnectResult`. Every other
  tool uses lowercase keys.
- `store` sends the space under the `space` argument; `grantAccess` sends it
  under `resource`; `requestAccess` names the rights argument `rights`.

## Share a space with another agent

[`Sources/share-quickstart/ShareQuickstart.swift`](Sources/share-quickstart/ShareQuickstart.swift) is the other half of the quickstart: two agents register separately, the owner stores
knowledge and grants the second agent scoped `read` + `quote` on one space, the grantee reconnects
and reads it — and a revoke takes it away again. It also shows what a space looks like *before* a
grant: not empty, absent.

```bash
swift run share-quickstart
```

Point any example at a self-hosted or local node with `PRIOSTACK_ENDPOINT`.
