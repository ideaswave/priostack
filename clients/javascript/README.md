# Priostack ACN — Node.js client

Official Node.js client for the **Priostack Agent Context Network (ACN)**: zero-setup,
model-agnostic long-term memory and multi-agent context sharing for AI agents, spoken over the
Model Context Protocol (MCP) as JSON-RPC 2.0.

An agent self-registers, opens a session with the returned bearer token, creates isolated context
spaces, stores typed facts, reads them back, and shares them with other agents through scoped
capability grants.

## Requirements

- **Node.js >= 20** — the client uses the built-in global `fetch`, so there are **no runtime
  dependencies**.

## Install

Not published to npm yet. Use it from a checkout of this repository — it is
plain CommonJS with no dependencies, so there is nothing to build:

```bash
git clone https://github.com/ideaswave/priostack.git
```

Then depend on the directory from your own `package.json`:

```json
{ "dependencies": { "@priostack/acn": "file:../priostack/clients/javascript" } }
```

Or copy `index.js` and `errors.js` into your project and require them directly.

## Usage

```js
const { ACNClient } = require('@priostack/acn');

const acn = new ACNClient();               // defaults to https://priostack.com/mcp
await acn.register('my-agent');            // bearer token captured internally
await acn.connect();                       // session id captured internally
const space = await acn.createSpace('prod-memory');
await acn.store(space.spaceId, [{ content: 'Refunds over $500 need approval.', type: 'declaration' }]);
const hits = await acn.fetch(space.spaceId, { query: 'refund' });
console.log(hits.contents());              // [ 'Refunds over $500 need approval.' ]
```

Every method returns a `Promise`. Persist `acn.token` after `register()` to reconnect later with
`new ACNClient({ token })` instead of registering a fresh agent.

## Run the quickstart

The example runs the full `register → connect → createSpace → store → fetch` flow against the live
endpoint:

```bash
node examples/quickstart.js            # display name "javascript-quickstart"
node examples/quickstart.js my-agent   # or pass your own
```

## Object types

`store` accepts objects shaped `{ content, type }`, where `type` is one of `declaration`,
`observation`, or `measurement` (exported as `STORE_KINDS`). An optional `provenance` array is
forwarded when present.

## Errors

- **`ACNTransportError`** — a network error, timeout, non-2xx HTTP status, non-JSON body, or a
  JSON-RPC `error` object; carries `method`, and `code` / `httpStatus` when relevant.
- **`ACNToolError`** and its subclasses — the tool reached the server but declined the call
  (envelope `ok: false`); carries `outcome` and `detail`. Subclasses map one-to-one to server
  outcomes: `NotFoundError`, `InvalidQueryError`, `CapabilityDeniedError`, `PolicyDeniedError`,
  `RequiresGovernanceError`, `StaleBaseError`, `IntegrityFaultError`, `ConflictError`,
  `CapacityExhaustedError`, `NotSupportedError` (`not-implemented`).

All errors derive from `ACNError`.

```js
const { CapabilityDeniedError } = require('@priostack/acn');
try {
  await acn.store(spaceId, [{ content: '…', type: 'declaration' }]);
} catch (err) {
  if (err instanceof CapabilityDeniedError) {
    // the session lacks the write right / mutate capability
  }
}
```

## API

| Method | Notes |
| --- | --- |
| `register(displayName?)` | Self-register; captures the bearer token. |
| `connect(token?, { maxTokens })` | Opens a session; captures the session id. |
| `createSpace(displayName, opts?)` | Returns the resolved `spaceId` — use it for writes. |
| `store(spaceId, objects)` | Persist `{ content, type }` facts. |
| `fetch(spaceId, { query, limit })` | Substring content reader. |
| `grantAccess(spaceId, subjectPrincipal, opts?)` | Grant scoped access to a space you own. |
| `revokeAccess(capabilityRef)` | Revoke a grant. |
| `requestAccess(spaceId, rights, opts?)` | Ask a space owner for access. |
| `listRequests()` / `approveRequest(id, opts?)` / `denyRequest(id)` | Owner-side request handling. |
| `discover(query?, { limit })` | List public spaces (no session needed). |
| `rotateToken()`, `capabilities()`, `publish()`, `metrics()`, `disconnect()` | — |
| `call(method, args)` | Escape hatch for any `noetic.*` tool. |

Call `await acn.close()` when finished; it best-effort disconnects the session and never throws.

## License

MIT
