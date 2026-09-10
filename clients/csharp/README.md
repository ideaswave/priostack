# Priostack ACN — .NET client

Official C#/.NET client for the [Priostack Agent Context Network (ACN)](https://priostack.com/agent-context-network):
zero-setup long-term memory and multi-agent context sharing for AI agents, over
the Model Context Protocol (MCP) / JSON-RPC 2.0.

An agent self-registers, opens a session with the returned bearer token, creates
isolated context spaces, stores typed facts, reads them back, and shares them
with other agents through scoped capability grants — all against the live
endpoint `https://priostack.com/mcp`.

- **Target:** .NET 8 (`net8.0`)
- **Dependencies:** none — uses `System.Net.Http` and `System.Text.Json` from the
  shared framework.

## Install

Reference the project directly:

```xml
<ProjectReference Include="path/to/clients/csharp/src/Priostack.Acn/Priostack.Acn.csproj" />
```

Or add the assembly once it is packed and published to your feed:

```bash
dotnet add package Priostack.Acn
```

## Usage

```csharp
using Priostack.Acn;

await using var acn = new AcnClient();                 // defaults to https://priostack.com/mcp
await acn.RegisterAsync("my-agent");                   // token captured internally
var conn = await acn.ConnectAsync();                   // session id captured internally
var space = await acn.CreateSpaceAsync("prod-memory");
await acn.StoreAsync(space.SpaceId, new[] { new StoreObject("Refunds over $500 need manager approval.", "declaration") });
foreach (var content in (await acn.FetchAsync(space.SpaceId, query: "refund")).Contents()) Console.WriteLine(content);
```

## Build and run the quickstart

From this directory (`clients/csharp/`):

```bash
# build the whole solution (library + quickstart)
dotnet build

# run the quickstart against the live endpoint
dotnet run --project examples/Quickstart -- csharp-sdk-smoke

# point at another deployment (positional or env var)
dotnet run --project examples/Quickstart -- my-agent https://priostack.com/mcp
PRIOSTACK_ENDPOINT=https://priostack.com/acn/rpc dotnet run --project examples/Quickstart
```

The quickstart runs `register → connect → createSpace → store → fetch` and prints
each step. Network calls fire only when the program is executed; referencing the
`Priostack.Acn` library from your own code triggers nothing on its own.

## API surface

| Method | Tool | Notes |
| --- | --- | --- |
| `RegisterAsync(displayName)` | `noetic.register` | captures `Token` |
| `ConnectAsync(token?, maxTokens)` | `noetic.connect` | captures `SessionId` from the **PascalCase** `SessionID` field |
| `CreateSpaceAsync(displayName, ...)` | `noetic.create_space` | use the returned `SpaceId` for writes |
| `StoreAsync(spaceId, objects)` | `noetic.store` | object `Type` ∈ `declaration` / `observation` / `measurement` |
| `FetchAsync(spaceId, query?, limit?)` | `noetic.fetch` | substring content reader |
| `GrantAccessAsync(spaceId, subjectPrincipal, ...)` | `noetic.grant` | `subjectPrincipal` is the grantee's agent id |
| `RevokeAccessAsync(capabilityRef)` | `noetic.revoke` | |
| `RequestAccessAsync(spaceId, rights, ...)` | `noetic.request_access` | |
| `ListRequestsAsync()` | `noetic.list_requests` | |
| `ApproveRequestAsync(requestId, ...)` | `noetic.approve_request` | |
| `DenyRequestAsync(requestId)` | `noetic.deny_request` | |
| `DiscoverAsync(query?, limit?)` | `noetic.discover` | no session required |
| `MetricsAsync()`, `CapabilitiesAsync()`, `RotateTokenAsync()`, `PublishAsync(...)`, `DisconnectAsync()` | `noetic.*` | |
| `CallAsync(method, arguments)` | any `noetic.*` | low-level escape hatch |

Every typed method also exposes the full server payload via a `Raw`
(`JsonElement`) property for fields not surfaced as typed members.

## Errors

- **Transport / protocol failures** (network error, non-2xx HTTP, non-JSON body,
  JSON-RPC `error`, a malformed envelope) throw `AcnTransportException`.
- **Tool failures** (envelope `ok: false`) throw a subclass of `AcnToolException`
  matching the server `outcome`, so you can catch exactly what you expect:

```csharp
try
{
    await acn.StoreAsync(spaceId, objects);
}
catch (AcnCapabilityDeniedException)
{
    // the session lacks the write right / mutate capability
}
```

Outcome map: `AcnNotFoundException`, `AcnInvalidQueryException`,
`AcnCapabilityDeniedException`, `AcnPolicyDeniedException`,
`AcnRequiresGovernanceException`, `AcnStaleBaseException`,
`AcnIntegrityFaultException`, `AcnConflictException`,
`AcnCapacityExhaustedException`, `AcnNotSupportedException` (`not-implemented`).
Unknown outcomes fall back to the `AcnToolException` base. All errors derive from
`AcnException`.

## Notes

- One pooled `HttpClient` is reused for every call; a `~30s` per-request timeout
  is enforced via a linked cancellation token so it applies even when you inject
  your own `HttpClient`. The JSON-RPC id increments atomically per call.
- Only `429`/`503` back-pressure responses are retried (with `Retry-After` /
  exponential backoff). Timeouts and network faults are **not** retried, so a
  non-idempotent `StoreAsync` is never silently duplicated.
- `await using` (or `DisposeAsync`) ends the session gracefully; `Dispose` just
  releases the HTTP client.

## License

MIT — see the repository `LICENSE`.
