# Priostack ACN — Swift client

Official Swift client for the [Priostack Agent Context Network (ACN)](https://priostack.com):
zero-setup, model-agnostic long-term memory and multi-agent context sharing for
AI agents, over the Model Context Protocol (MCP).

Pure Foundation — `URLSession` + `Codable` + `async`/`await`. No third-party
dependencies.

## Requirements

- Swift 5.9+ (macOS 12+, iOS 15+, or Linux with the Swift toolchain).

## Install

Add the package to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/priostack/priostack", from: "0.2.0"),
],
targets: [
    .target(
        name: "YourApp",
        dependencies: [.product(name: "PriostackACN", package: "priostack")]
    ),
]
```

Or, in Xcode: *File ▸ Add Package Dependencies…* and point it at the repo, then
add the **PriostackACN** library product to your target.

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
