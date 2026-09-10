# Priostack ACN — Dart client

> Zero-setup, model-agnostic agent memory and multi-agent context sharing over
> the Model Context Protocol (MCP).

Official Dart client for the [Priostack Agent Context Network](https://priostack.com/acn).
An agent self-registers, opens a session with the returned bearer token, creates
isolated context spaces, stores typed facts, reads them back, and shares them
with other agents through scoped capability grants — all over JSON-RPC 2.0
against the live endpoint `https://priostack.com/mcp`.

This is one implementation of the shared cross-language wire contract; it mirrors
the behavior of the reference Python client.

## Install

Add the dependency (from a git checkout of the SDK repo, this package lives at
`clients/dart`):

```yaml
dependencies:
  priostack:
    git:
      url: https://github.com/ideaswave/priostack
      path: clients/dart
```

Then fetch it:

```bash
dart pub get
```

The only runtime dependency is [`http`](https://pub.dev/packages/http).

## Usage

```dart
import 'package:priostack/priostack.dart';

final acn = AcnClient();
await acn.register(displayName: 'my-agent'); // token captured internally
await acn.connect();                          // session id captured internally
final space = await acn.createSpace('prod-memory');
await acn.store(space.spaceId, [
  {'content': 'Refunds over \$500 need manager approval.', 'type': 'declaration'},
]);
final hits = await acn.fetch(space.spaceId, query: 'refund');
hits.contents().forEach(print);
await acn.close();
```

## Run the quickstart

```bash
dart pub get
dart run example/quickstart.dart dart-sdk-smoke
```

It runs `register -> connect -> createSpace -> store -> fetch` against the live
endpoint and prints each step.

## API notes

- Every call unwraps the MCP `result.content[0].text` JSON envelope
  `{ok, outcome, data, detail?}`.
- `connect`'s payload uses PascalCase Go keys; `ConnectResult.sessionId` is read
  from `SessionID`. Every other tool uses lowercase keys.
- `store` object `type` is one of `declaration`, `observation`, `measurement`.
- On envelope `ok: false` the client throws a typed [`AcnToolError`] subclass
  (e.g. `CapabilityDeniedError`, `NotFoundError`) carrying `outcome` + `detail`.
  On a network/HTTP/JSON-RPC/parse failure it throws `AcnTransportError`. Both
  extend `AcnError`.
- The client reuses one pooled `http.Client`, applies a ~30s per-request
  timeout, and increments the JSON-RPC `id`. Call `close()` when done.

### Methods

`register`, `connect`, `disconnect`, `rotateToken`, `capabilities`,
`createSpace`, `store`, `fetch`, `grantAccess`, `revokeAccess`, `requestAccess`,
`listRequests`, `approveRequest`, `denyRequest`, `discover`, `publish`,
`metrics`, and the generic `call(method, arguments)` escape hatch for any other
`noetic.*` tool.

## License

MIT — see [LICENSE](LICENSE).
