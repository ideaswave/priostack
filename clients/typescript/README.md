# @priostack/acn — TypeScript SDK

Official TypeScript/JavaScript client for the **Priostack Agent Context Network (ACN)** — zero-setup,
model-agnostic long-term memory and multi-agent context sharing for AI agents, over the Model Context
Protocol (MCP).

It speaks the exact wire contract of the live server: JSON-RPC 2.0 `tools/call`, unwrapping the MCP
`result.content[0].text` envelope, throwing typed errors on tool-level denials, and capturing the
session id automatically on `connect()`.

## Requirements

- Any runtime with a global `fetch`: Node.js **18+**, Deno, Bun, or a modern browser (the endpoint is
  CORS-enabled). On older runtimes, inject a `fetch` via the constructor.

## Install

Not published to npm yet. Build it from a checkout of this repository:

```bash
git clone https://github.com/ideaswave/priostack.git
cd priostack/clients/typescript && npm install && npm run build
```

Then depend on the directory from your own `package.json`:

```json
{ "dependencies": { "@priostack/acn": "file:../priostack/clients/typescript" } }
```

The build writes JavaScript and `.d.ts` files to `dist/src`. The TypeScript
sources ship too, so you can also add `src/` to your own `tsconfig.json`.

## Usage

```ts
import { ACNClient } from "@priostack/acn";

const acn = new ACNClient();
await acn.register("my-agent");            // token captured internally
await acn.connect();                       // session id captured internally
const space = await acn.createSpace("prod-memory");
await acn.store(space.spaceId, [{ content: "Refunds over $500 need approval.", type: "declaration" }]);
const hits = await acn.fetch(space.spaceId, { query: "refund" });
```

## Build from source

```bash
git clone https://github.com/ideaswave/priostack
cd priostack/clients/typescript
npm install
npm run build       # compile to dist/
npm run typecheck   # type-check without emitting
```

## Run the quickstart

Registers a throwaway agent against the live ACN, stores two facts, and reads one back:

```bash
npm run build
node dist/examples/quickstart.js
```

## API

The client maps each `noetic.*` tool to an idiomatic method. Typed result interfaces
(`RegisterResult`, `ConnectResult`, `SpaceResult`, `StoreResult`, `FetchResult`, `GrantResult`) are
exported alongside the client.

| Method | Tool | Notes |
| :--- | :--- | :--- |
| `register(displayName)` | `noetic.register` | Captures the bearer token on the client. |
| `connect(token?, { maxTokens })` | `noetic.connect` | Captures the session id (`data.SessionID`). |
| `createSpace(displayName, opts?)` | `noetic.create_space` | Use the **returned** `spaceId` for writes. |
| `store(spaceId, objects)` | `noetic.store` | `type` ∈ `declaration` \| `observation` \| `measurement`. |
| `fetch(spaceId, { query, limit })` | `noetic.fetch` | Case-insensitive substring reader (not semantic). |
| `grantAccess(spaceId, subjectPrincipal, opts?)` | `noetic.grant` | `subjectPrincipal` is the grantee's `agentId`. |
| `revokeAccess(capabilityRef)` | `noetic.revoke` | |
| `requestAccess(spaceId, rights, opts?)` | `noetic.request_access` | Consumer side. |
| `listRequests()` / `approveRequest(id, opts?)` / `denyRequest(id)` | `noetic.list_requests` / `approve_request` / `deny_request` | Owner side. |
| `discover(query?, { limit })` | `noetic.discover` | No session required. |
| `metrics()` / `disconnect()` / `rotateToken()` / `capabilities()` / `publish()` | `noetic.*` | |
| `call(method, args)` | any | Low-level escape hatch returning the unwrapped `data`. |

## Error handling

Two branches, both deriving from `ACNError`:

- **`ACNTransportError`** — the request never produced a valid envelope (network error, timeout,
  non-2xx HTTP, non-JSON body, or a JSON-RPC `error`).
- **`ACNToolError`** and its subclasses — the tool returned `ok: false`. Catch a specific outcome:

```ts
import { ACNClient, CapabilityDeniedError } from "@priostack/acn";

try {
  await acn.store(spaceId, [{ content: "…", type: "declaration" }]);
} catch (err) {
  if (err instanceof CapabilityDeniedError) {
    // the session lacks the write right / mutate capability
  } else {
    throw err;
  }
}
```

Subclasses: `NotFoundError`, `InvalidQueryError`, `CapabilityDeniedError`, `PolicyDeniedError`,
`RequiresGovernanceError`, `StaleBaseError`, `IntegrityFaultError`, `ConflictError`,
`CapacityExhaustedError`, `NotSupportedError`.

## License

MIT. See the repository `LICENSE`.
