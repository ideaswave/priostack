# Priostack ACN — Ruby client

Official Ruby client for the [Priostack](https://priostack.com) Agent Context
Network (ACN): model-agnostic, zero-setup long-term memory and multi-agent
context sharing for AI agents, over the Model Context Protocol (MCP).

An agent self-registers, opens a session with the returned bearer token, creates
isolated context spaces, stores typed facts, reads them back, and shares them
with other agents through scoped capability grants.

- **No runtime dependencies.** Pure Ruby standard library (`net/http`, `json`,
  `uri`).
- **Ruby >= 3.0.**

## Install

From RubyGems:

```sh
gem install priostack
```

In a `Gemfile`:

```ruby
gem "priostack"
```

Or use it straight from this directory without installing — the library is
plain stdlib Ruby:

```sh
ruby -Ilib examples/quickstart.rb
```

To build the gem locally:

```sh
gem build priostack.gemspec
```

## Usage

```ruby
require "priostack"

Priostack::Client.open do |acn|
  acn.register("my-agent")                        # token captured internally
  acn.connect                                     # session id captured internally
  space = acn.create_space("prod-memory")
  acn.store(space.space_id, [{ content: "Refunds over $500 need manager approval.", type: "declaration" }])
  acn.fetch(space.space_id, query: "refund").contents.each { |c| puts c }
end
```

`Client.open` yields a client and disconnects on the way out. Without a block it
returns the client and you call `#close` yourself.

## Run the quickstart

The quickstart walks the full path — register → connect → create space → store →
fetch — against the live endpoint:

```sh
ruby examples/quickstart.rb
```

Override the target or the registered display name via the environment:

```sh
PRIOSTACK_ENDPOINT=https://priostack.com/mcp \
PRIOSTACK_DISPLAY_NAME=ruby-sdk-smoke \
  ruby examples/quickstart.rb
```

## Errors

Every failure derives from `Priostack::Error`:

- `Priostack::TransportError` — a network error, non-2xx HTTP status, non-JSON
  body, or a JSON-RPC `error` object; the call never produced a valid tool
  envelope. Carries `#http_status` / `#code` when applicable.
- `Priostack::ToolError` — the tool ran but declined the call (envelope
  `ok: false`). Carries `#outcome` and `#detail`. Rescue a specific subclass to
  handle one outcome:

  | outcome               | class                              |
  | --------------------- | ---------------------------------- |
  | `not-found`           | `NotFoundError`                    |
  | `invalid-query`       | `InvalidQueryError`                |
  | `capability-denied`   | `CapabilityDeniedError`            |
  | `policy-denied`       | `PolicyDeniedError`                |
  | `requires-governance` | `RequiresGovernanceError`          |
  | `stale-base`          | `StaleBaseError`                   |
  | `integrity-fault`     | `IntegrityFaultError`              |
  | `conflict`            | `ConflictError`                    |
  | `capacity-exhausted`  | `CapacityExhaustedError`           |
  | `not-implemented`     | `NotSupportedError`                |

```ruby
begin
  acn.store(space_id, objects)
rescue Priostack::CapabilityDeniedError
  # the session lacks the write right / mutate capability
end
```

## Method surface

Identity: `register`, `connect`, `disconnect`, `rotate_token`, `capabilities`.
Spaces + facts: `create_space`, `store`, `fetch`.
Sharing: `grant_access`, `revoke_access`, `request_access`, `list_requests`,
`approve_request`, `deny_request`.
Discovery + introspection: `discover` (no session needed), `publish`, `metrics`.

`store` object types are `declaration`, `observation`, and `measurement`
(`Priostack::STORE_KINDS`). For any tool this client does not wrap, use the
escape hatch `acn.call("noetic.<tool>", { ...arguments })`, which returns the
unwrapped `data` hash and raises the same typed errors.
