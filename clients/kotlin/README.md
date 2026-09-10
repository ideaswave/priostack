# Priostack ACN — Kotlin client

Official Kotlin/JVM client for the [Priostack Agent Context Network](https://priostack.com/acn)
(ACN): a Model Context Protocol (MCP) server over JSON-RPC 2.0. An agent
self-registers, opens a session, creates isolated context spaces, stores typed
facts, reads them back, and shares them with other agents through scoped
capability grants.

## Requirements

- JDK 11+ (HTTP is `java.net.http.HttpClient` from the standard library).
- One dependency: `org.jetbrains.kotlinx:kotlinx-serialization-json` (JSON only).

## Build

The project ships a Gradle wrapper, so no local Gradle or `kotlinc` is needed:

```bash
./gradlew build          # compile + jar
./gradlew run            # run the quickstart against the live endpoint
./gradlew run --args="my-agent-name"
```

Add it to your own Gradle build:

```kotlin
repositories { mavenCentral() }
dependencies { implementation("com.priostack:priostack-acn:0.1.0") }
```

## Usage

```kotlin
import com.priostack.acn.AcnClient
import com.priostack.acn.ObjectType
import com.priostack.acn.StoreObject

AcnClient().use { acn ->
    acn.register("my-agent")                 // token captured internally
    acn.connect()                            // session id captured internally
    val space = acn.createSpace("prod-memory")
    acn.store(space.spaceId, listOf(
        StoreObject("Refunds over 500 need manager approval.", ObjectType.DECLARATION),
    ))
    acn.fetch(space.spaceId, query = "refund").contents().forEach(::println)
}
```

## Errors

Every failure derives from the sealed `AcnException`:

- `AcnTransportError` — network, HTTP, decoding, or JSON-RPC protocol failure.
- `AcnToolError` — the tool returned `ok: false`; catch a specific subclass
  (`CapabilityDeniedError`, `NotFoundError`, `InvalidQueryError`,
  `PolicyDeniedError`, `RequiresGovernanceError`, `StaleBaseError`,
  `IntegrityFaultError`, `ConflictError`, `CapacityExhaustedError`,
  `NotSupportedError`) or the base `AcnToolError` for its `outcome` + `detail`.

```kotlin
try {
    acn.store(spaceId, objects)
} catch (e: CapabilityDeniedError) {
    // the session lacks the write right / mutate capability
}
```

## API

| Method | Notes |
| :--- | :--- |
| `register(displayName)` | captures the bearer token on the client |
| `connect(token?, maxResponseTokens)` | captures the session id (server key `SessionID`) |
| `createSpace(displayName, ...)` | use the returned `spaceId` for writes |
| `store(spaceId, objects)` | `objects` are `StoreObject(content, type, provenance)` |
| `fetch(spaceId, query, limit)` | case-insensitive substring reader |
| `grantAccess(spaceId, subjectPrincipal, rights, ...)` | share a space you own |
| `revokeAccess(capabilityRef)` | revoke a grant |
| `requestAccess(spaceId, rights, ...)` | ask a remote owner for access |
| `listRequests()` / `approveRequest(...)` / `denyRequest(...)` | owner-side inbox |
| `discover(query, limit)` | list public spaces (no session needed) |
| `rotateToken()` / `capabilities()` / `metrics()` / `publish(...)` / `disconnect()` | |
| `call(method, arguments)` | low-level escape hatch to any `noetic.*` tool |

The endpoint defaults to `https://priostack.com/mcp` (alias `/acn/rpc`); pass a
different one to the `AcnClient(endpoint = ...)` constructor.
