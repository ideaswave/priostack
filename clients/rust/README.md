# priostack-acn — Rust client for the Priostack ACN

Official Rust client for the Priostack Agent Context Network (ACN), an MCP
server reached over JSON-RPC 2.0. An agent self-registers, opens a session,
creates isolated context spaces, stores typed facts, reads them back, and shares
them with other agents through scoped capability grants.

The client unwraps the MCP `result.content[0].text` envelope for you, reuses one
pooled HTTPS connection, and captures the bearer token and session id
automatically. Tool-level denials surface as `Error::Tool` (carrying the server
`outcome` and `detail`); network/HTTP/JSON-RPC/parse failures surface as
`Error::Transport`.

## Install

Add it to your `Cargo.toml` (path dependency shown; adjust to your layout):

```toml
[dependencies]
priostack-acn = { path = "clients/rust" }
```

It depends on a single well-known crate, `reqwest` (blocking, `rustls-tls`), which
pulls in `serde_json`. No system OpenSSL is required.

## Build & test

```sh
cargo build                       # compile the library
cargo run --example quickstart    # register -> connect -> store -> fetch, live
```

The quickstart runs every network call inside `main`, so building the library
never fires a request. Override the target with `PRIOSTACK_ENDPOINT` and the
agent name with `PRIOSTACK_DISPLAY_NAME`.

## Usage

```rust
use priostack_acn::{Client, Object};

let acn = Client::new()?;                               // https://priostack.com/mcp
acn.register("my-agent")?;                              // token captured internally
acn.connect()?;                                         // session id captured internally
let space = acn.create_space("prod-memory", &[])?;      // use the RETURNED space_id
acn.store(&space.space_id, &[Object::declaration("Refunds over $500 need manager approval.")])?;
let hits = acn.fetch(&space.space_id, "refund", 0)?;     // substring reader, not semantic
```

### Sharing a space with another agent

```rust
// owner grants the grantee agent id read+quote on the space
let grant = acn.grant_access(&space.space_id, grantee_agent_id, &["read", "quote"], None)?;
// ... later, forward-only revoke:
acn.revoke_access(&grant.capability_ref)?;
```

### Handling failures

```rust
use priostack_acn::{Error, Outcome};

match acn.store(&space_id, &[Object::declaration("x")]) {
    Ok(res) => println!("stored {}", res.count()),
    Err(Error::Tool { outcome: Outcome::CapabilityDenied, detail, .. }) =>
        eprintln!("not allowed to write: {detail}"),
    Err(Error::Transport { message, .. }) => eprintln!("transport failure: {message}"),
    Err(e) => eprintln!("{e}"),
}
```

## Surface

Typed methods: `register`, `connect` / `connect_with`, `disconnect`,
`rotate_token`, `capabilities`, `create_space`, `store`, `fetch`,
`grant_access`, `revoke_access`, `request_access`, `list_requests`,
`approve_request`, `deny_request`, `discover`, `publish`, `metrics`.

For any of the other `noetic.*` tools, use the escape hatch:

```rust
let data = acn.call("noetic.query", serde_json::json!({ "sessionId": sid, "space": space_id }))?;
```

## Notes

- Call `disconnect()` when you are done; the client does not disconnect in
  `Drop` (a blocking network call in a destructor is a footgun). Durable facts
  survive a disconnect — they are not revoked.
- `connect` reads the session id from the server's **PascalCase** `SessionID`
  field; every other tool uses lowercase keys. The client handles this for you.
- `Client` is `Send + Sync`; wrap it in an `Arc` to share across threads.

## License

MIT.
