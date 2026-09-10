# Priostack ACN — Java client

Official Java client for the [Priostack Agent Context Network (ACN)](https://priostack.com/acn):
zero-setup, model-agnostic long-term memory and multi-agent context sharing for AI agents, over
the Model Context Protocol (MCP).

An agent self-registers, opens a session with the returned bearer token, creates isolated context
spaces, stores typed facts, reads them back, and shares them with other agents through scoped
capability grants. The client speaks the exact JSON-RPC 2.0 wire contract of the live server: it
unwraps the MCP `result.content[0].text` envelope, raises a typed `ACNToolError` on tool-level
denials, and reuses one pooled `HttpClient`.

## Requirements

- JDK 21+ (uses `java.net.http.HttpClient`)
- Maven 3.8+

The only runtime dependency is Jackson (`com.fasterxml.jackson.core:jackson-databind:2.17.2`) for
JSON; HTTP is the JDK's built-in client.

## Build

```bash
mvn -q -DskipTests compile      # compile the library + example
mvn -q package                  # build the jar under target/
mvn -q install                  # install to your local ~/.m2 as com.priostack:priostack-acn-client:0.2.0
```

Add it to another Maven project once installed:

```xml
<dependency>
  <groupId>com.priostack</groupId>
  <artifactId>priostack-acn-client</artifactId>
  <version>0.2.0</version>
</dependency>
```

## Run the quickstart

The `Quickstart` example runs register → connect → createSpace → store → fetch against the live
endpoint and prints each step. The optional first argument is the display name to register under;
the optional second overrides the endpoint (default `https://priostack.com/mcp`).

```bash
mvn -q compile
mvn -q exec:java -Dexec.args="java-sdk-smoke"
```

## Usage

```java
try (ACNClient acn = new ACNClient()) {
    acn.register("my-agent");                 // token captured internally
    acn.connect();                            // session id captured internally
    SpaceResult space = acn.createSpace("prod-memory");
    acn.store(space.spaceId(), List.of(
        StoreObject.declaration("Refunds over $500 need manager approval.")));
    acn.fetch(space.spaceId(), "refund").contents().forEach(System.out::println);
}
```

## Notes / gotchas

- **Object types**: `store` accepts only `declaration`, `observation`, and `measurement` — use the
  `StoreObject.declaration(...)` / `.observation(...)` / `.measurement(...)` factories (the
  `ObjectType` enum guards this at compile time). Anything else is rejected with `invalid-query`.
- **`fetch` is a content reader**: `query` is a case-insensitive substring filter over content, not
  semantic search.
- **Sharing** (`grantAccess`): `subjectPrincipal` is the grantee's `agentId`; `rights` default to
  `[read, quote]`. Re-`connect` after being granted access so the widened scope applies.
- **Errors**: transport/protocol failures throw `ACNTransportError`; a tool that declines the call
  (`ok: false`) throws the matching `ACNToolError` subclass — `CapabilityDeniedError`,
  `NotFoundError`, `InvalidQueryError`, `PolicyDeniedError`, `RequiresGovernanceError`,
  `StaleBaseError`, `IntegrityFaultError`, `ConflictError`, `CapacityExhaustedError`,
  `NotSupportedError` — each carrying `outcome()` and `detail()`. Catch `ACNError` for either.
- **Escape hatch**: `acn.call("noetic.<tool>", Map.of(...))` reaches any tool this client does not
  wrap, returning the unwrapped `data` as a Jackson `JsonNode`.

## License

See the repository root.
