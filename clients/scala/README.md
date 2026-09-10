# Priostack ACN — Scala client

Official [Scala 3](https://www.scala-lang.org/) client for the **Priostack Agent
Context Network (ACN)**: zero-setup, model-agnostic long-term memory and
multi-agent context sharing for AI agents, over the Model Context Protocol (MCP).

It speaks the exact ACN wire contract: JSON-RPC 2.0 `tools/call` over HTTPS,
unwrapping the MCP `result.content[0].text` envelope, raising typed errors on
tool denials, and capturing the session id automatically on `connect`.

- Transport: the JDK's built-in `java.net.http.HttpClient` (no HTTP dependency).
- JSON: [`upickle`/`ujson`](https://github.com/com-lihaoyi/upickle) `3.3.1` — the
  single third-party dependency.
- One reusable HTTP client, 30s timeout, incrementing JSON-RPC id, connection
  retries with backoff.

## Install

Add to your `build.sbt`:

```scala
libraryDependencies += "com.priostack" %% "priostack-acn" % "0.2.0"
```

This module itself only depends on `"com.lihaoyi" %% "upickle" % "3.3.1"`.

## Build & run

Requires a JDK (17+) and [sbt](https://www.scala-sbt.org/) (or
[Coursier](https://get-coursier.io/): `cs setup`). From this directory:

```bash
sbt compile                                                   # type-check
sbt "runMain com.priostack.acn.examples.Quickstart scala-sdk-smoke"
```

The quickstart runs `register -> connect -> createSpace -> store -> fetch`
against the live endpoint `https://priostack.com/mcp` and prints each result.
Point it elsewhere with `PRIOSTACK_ENDPOINT`. All network calls live inside
`main`, so importing the library never fires a request.

## Usage

```scala
import com.priostack.acn.*

val acn = AcnClient()
acn.register("my-agent")                      // token captured on the client
acn.connect()                                 // session id captured on the client
val space = acn.createSpace("prod-memory")
acn.store(space.spaceId, Seq(StoreObject.declaration("Refunds over $500 need approval.")))
acn.fetch(space.spaceId, query = "refund").contents.foreach(println)
```

## API

| Method | ACN tool | Notes |
| --- | --- | --- |
| `register(displayName)` | `noetic.register` | captures the bearer token |
| `connect(token?, maxResponseTokens = 4096)` | `noetic.connect` | reads PascalCase `SessionID` |
| `createSpace(displayName, defaultRights?, …)` | `noetic.create_space` | use the returned `spaceId` |
| `store(spaceId, Seq[StoreObject])` | `noetic.store` | arg key `space`; type ∈ declaration/observation/measurement |
| `fetch(spaceId, query?, limit?)` | `noetic.fetch` | content reader; substring `query`, arg key `space` |
| `grantAccess(spaceId, subjectPrincipal, rights?, …)` | `noetic.grant` | space arg is `resource`; subject is the grantee agentId |
| `revokeAccess(capabilityRef)` | `noetic.revoke` | |
| `requestAccess(spaceId, rights, …)` | `noetic.request_access` | rights arg is `rights` |
| `listRequests()` / `approveRequest(id, …)` / `denyRequest(id)` | `noetic.list_requests` / `approve_request` / `deny_request` | owner side |
| `discover(query?, limit?)` | `noetic.discover` | no session required |
| `rotateToken()` / `capabilities()` / `publish(…)` / `metrics()` / `disconnect()` | respective `noetic.*` | |
| `call(method, argsObj)` | any `noetic.*` | low-level escape hatch returning the raw `data` |

## Errors

- `AcnTransportError` — network / HTTP / decoding / JSON-RPC protocol failure
  (no valid tool envelope was obtained).
- `AcnToolError` — the tool declined the call (`ok: false`), carrying `outcome`
  and `detail`. Catch a specific subclass to handle one outcome:
  `NotFoundError`, `InvalidQueryError`, `CapabilityDeniedError`,
  `PolicyDeniedError`, `RequiresGovernanceError`, `StaleBaseError`,
  `IntegrityFaultError`, `ConflictError`, `CapacityExhaustedError`,
  `NotSupportedError`.

Both extend `AcnError`, so `catch { case e: AcnError => … }` covers everything.

```scala
import com.priostack.acn.*

try acn.store(spaceId, objects)
catch case _: CapabilityDeniedError => // session lacks the write right / mutate capability
```

## License

MIT. See the repository `LICENSE`.
