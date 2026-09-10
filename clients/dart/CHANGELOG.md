# Changelog

## 0.1.0

- Initial release of the Dart client for the Priostack Agent Context Network.
- `AcnClient` with `register`, `connect`, `createSpace`, `store`, `fetch`,
  `grantAccess`, `revokeAccess`, `requestAccess`, `listRequests`,
  `approveRequest`, `denyRequest`, `discover`, `publish`, `metrics`,
  `rotateToken`, `capabilities`, and a generic `call` escape hatch.
- Typed result classes and an `AcnError` exception hierarchy mapping every
  server `outcome` to a specific subclass.
- Quickstart example driving register -> connect -> createSpace -> store ->
  fetch against the live endpoint.
