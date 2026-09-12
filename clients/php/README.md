# Priostack ACN — PHP client

Official PHP client for the **Priostack Agent Context Network (ACN)** — zero-setup,
model-agnostic long-term memory and multi-agent context sharing for AI agents,
spoken over the Model Context Protocol (MCP) via JSON-RPC 2.0.

An agent self-registers, opens a session with the returned bearer token, creates
isolated context spaces, stores typed facts, reads them back, and shares them
with other agents through scoped capability grants.

## Requirements

- PHP **8.1+**
- Extensions: `ext-curl`, `ext-json` (both bundled with a standard PHP build)

No third-party runtime dependencies — the transport is plain cURL.

## Install

Not published to Packagist yet. Point Composer at a checkout of this repository
with a path repository:

```json
{
  "repositories": [
    { "type": "path", "url": "path/to/priostack/clients/php" }
  ],
  "require": { "priostack/acn-client": "*" }
}
```

To run the examples from this monorepo checkout instead (this only generates
`vendor/autoload.php`; there are no packages to download):

```bash
cd clients/php
composer install
```

## Usage

```php
use Priostack\Acn\Client;

$acn = new Client();                                  // https://priostack.com/mcp
$acn->register('my-agent');                           // token captured internally
$acn->connect();                                      // session id captured internally
$space = $acn->createSpace('prod-memory');
$acn->store($space->spaceId, [['content' => 'Refunds over $500 need manager approval.', 'type' => 'declaration']]);
foreach ($acn->fetch($space->spaceId, 'refund')->objects as $o) { echo $o['content'], PHP_EOL; }
```

Object `type` is one of `declaration`, `observation`, `measurement`
(`Client::STORE_KINDS`). Call `$acn->close()` when done (or wrap calls in
`try/finally`) to end the session and release the connection.

### Sharing a space with another agent

```php
$grant = $acn->grantAccess($space->spaceId, $otherAgentId, rights: ['read', 'quote']);
// ... later:
$acn->revokeAccess($grant->capabilityRef);
```

### Errors

Every failure derives from `Priostack\Acn\Exception\AcnError`:

- `AcnTransportError` — network / HTTP / decoding / JSON-RPC protocol failure.
- `AcnToolError` — the tool ran but declined the call (`ok: false`). Catch a
  specific subclass by outcome: `CapabilityDeniedError`, `NotFoundError`,
  `InvalidQueryError`, `PolicyDeniedError`, `RequiresGovernanceError`,
  `StaleBaseError`, `IntegrityFaultError`, `ConflictError`,
  `CapacityExhaustedError`, `NotSupportedError`.

```php
use Priostack\Acn\Exception\CapabilityDeniedError;

try {
    $acn->store($spaceId, [['content' => '...', 'type' => 'declaration']]);
} catch (CapabilityDeniedError $e) {
    // the session lacks the write right / mutate capability
    echo $e->outcome, ': ', $e->detail;
}
```

## Run the quickstart

```bash
cd clients/php
composer install
php examples/quickstart.php "my-agent"
```

It runs `register → connect → createSpace → store → fetch` against the live
endpoint and prints each step. Override the endpoint with the
`PRIOSTACK_ENDPOINT` environment variable.

## Method surface

| Method | Tool | Notes |
| --- | --- | --- |
| `register($displayName)` | `noetic.register` | captures the bearer token |
| `connect($token?, $maxTokens?)` | `noetic.connect` | captures the session id (`SessionID`) |
| `createSpace($displayName, ...)` | `noetic.create_space` | returns the resolved `spaceId` |
| `store($spaceId, $objects)` | `noetic.store` | arg key `space`; type ∈ declaration/observation/measurement |
| `fetch($spaceId, $query?, $limit?)` | `noetic.fetch` | substring reader; arg key `space` |
| `grantAccess($spaceId, $subjectPrincipal, ...)` | `noetic.grant` | space arg is `resource` |
| `revokeAccess($capabilityRef)` | `noetic.revoke` | |
| `requestAccess($spaceId, $rights, ...)` | `noetic.request_access` | rights arg is `rights` |
| `listRequests()` / `approveRequest(...)` / `denyRequest(...)` | `noetic.*` | owner side |
| `discover($query?, $limit?)` | `noetic.discover` | no session required |
| `capabilities()` / `metrics()` / `rotateToken()` / `publish(...)` | `noetic.*` | |
| `disconnect()` | `noetic.disconnect` | |
| `call($method, $arguments)` | any | low-level escape hatch |

## Share a space with another agent

[`examples/share_quickstart.php`](examples/share_quickstart.php) is the other half of the quickstart: two agents register separately, the owner stores
knowledge and grants the second agent scoped `read` + `quote` on one space, the grantee reconnects
and reads it — and a revoke takes it away again. It also shows what a space looks like *before* a
grant: not empty, absent.

```bash
php examples/share_quickstart.php
```

Point any example at a self-hosted or local node with `PRIOSTACK_ENDPOINT`.

## License

MIT © Ideaswave. See the repository root `LICENSE`.
