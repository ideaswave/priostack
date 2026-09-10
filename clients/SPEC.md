# Priostack ACN client — implementation spec (all languages)

Every language client in `clients/<lang>/` implements the SAME wire contract. The authoritative
contract is `../../CONTRACT.md`-equivalent, reproduced here. The verified reference implementation is
the Python client at `../src/priostack/client.py` (+ `../src/priostack/exceptions.py`) — read it; port
its behavior idiomatically, do not invent a different shape.

The live endpoint `https://priostack.com/mcp` (alias `https://priostack.com/acn/rpc`) is up and
CORS-enabled, so a client can be smoke-tested against it.

## Transport (identical in every language)
- HTTP `POST` JSON-RPC 2.0 to the endpoint (default `https://priostack.com/mcp`).
- Request body: `{"jsonrpc":"2.0","id":<n>,"method":"tools/call","params":{"name":"<tool>","arguments":{...}}}`
- Response body: `{"jsonrpc":"2.0","id":<n>,"result":{"content":[{"type":"text","text":"<ENVELOPE_JSON_STRING>"}],"isError":<bool>}}`
- **You MUST parse `result.content[0].text` as JSON** to get the envelope `{ok,outcome,data,detail?,receipt?}`.
- Set request headers `Content-Type: application/json` and `Accept: application/json`.
- On envelope `ok=false`: raise/return a typed error carrying `outcome` + `detail`. Map outcomes:
  not-found, invalid-query, capability-denied, policy-denied, requires-governance, stale-base,
  integrity-fault, conflict, capacity-exhausted, not-implemented.
- On a top-level JSON-RPC `error` object, or a non-2xx HTTP status, or a non-JSON body: raise a
  transport error.
- Use one reusable HTTP client/connection; set a sane timeout (~30s). Increment the JSON-RPC `id`.

## Methods to implement (map to language-idiomatic names)
- `register(displayName) -> {token, agentId, accountId, tier}`  (capture token on the client)
- `connect(token, maxResponseTokens=4096) -> {sessionId, ...}`
    **CRITICAL: the connect envelope `data` uses PascalCase Go field names: `SessionID`,
    `ResolvedAccount`, `GrantedCapabilities`, `GrantedContextRights`, `BoundSpace`,
    `ResolvedMaxTokens`.** Capture `data.SessionID` as the session id. (All OTHER tools use lowercase
    keys.) Store the session id on the client; later calls send `sessionId`.
- `createSpace(displayName, defaultRights?) -> {spaceId, ...}`  (use the RETURNED spaceId for writes)
- `store(spaceId, objects) -> {objectRefs}`  each object `{content, type}`, type ∈
    {declaration, observation, measurement}. arg key is `space` (the space id).
- `fetch(spaceId, query?, limit?) -> {space, objects:[{objectRef,kind,content,tokens}], matched, total, returnedTokens}`
    (this is the content reader; substring `query`, not semantic). arg key is `space`.
- `grantAccess(spaceId, subjectPrincipal, rights=[read,quote], worldMutation?) -> {capabilityRef, ...}`
    **the space arg is named `resource` (not `space`)**. subjectPrincipal is the grantee's agentId.
- `revokeAccess(capabilityRef) -> {...}`
- `requestAccess(spaceId, rights, reason?) -> {...}`  **the rights arg is named `rights`** (space arg `space`).
- `listRequests() -> [requests]`
- `approveRequest(requestId, rights?, worldMutation?) -> {capabilityRef, ...}`
- `discover(query?, limit?) -> [spaces]`  (no session needed)
- `metrics() -> {...}` ; `disconnect() -> {...}`
- a generic `call(method, argumentsMap) -> data` escape hatch used by all of the above.

## Deliverables per language dir `clients/<lang>/`
1. The client library (idiomatic package/module layout for that language).
2. A `quickstart` example: register → connect → createSpace → store → fetch, printing results.
   Wrap live calls in a main/guard so importing the library does not fire network calls.
3. A short `README.md`: install/build + run instructions, and a 6-line usage snippet.
4. If the language's toolchain is installed on this machine, COMPILE/type-check it and, if trivial,
   run the quickstart against the live endpoint once (use a display name like
   `"<lang>-sdk-smoke"`). Report exactly what you verified vs. only authored.

## Rules
- Match the surrounding style of a well-run project in that language. No TODOs, no stubs, no dead code.
- Only edit files under your own `clients/<lang>/` directory. Do NOT touch the repo root, other
  language dirs, the Python `src/`, or CI — those are handled centrally.
- Prefer the standard library / a single well-known HTTP+JSON dependency. Pin versions where a
  manifest is used. Keep the dependency set minimal.
- Return a concise report: files created, dependency choices, and verification performed (compiled?
  ran live? just authored?).
