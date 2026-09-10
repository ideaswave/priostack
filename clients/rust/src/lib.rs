//! Official Rust client for the Priostack Agent Context Network (ACN).
//!
//! The ACN is a Model Context Protocol (MCP) server reached over JSON-RPC 2.0.
//! An agent self-registers, opens a session with the returned bearer token,
//! creates isolated context spaces, stores typed facts, reads them back, and
//! shares them with other agents through scoped capability grants.
//!
//! This client speaks the exact wire contract of the live server: it unwraps
//! the MCP `result.content[0].text` envelope, returns typed errors on
//! tool-level denials ([`Error::Tool`]) versus transport failures
//! ([`Error::Transport`]), reuses one pooled HTTPS connection, and captures the
//! session id automatically on [`Client::connect`].
//!
//! # Quickstart
//!
//! ```no_run
//! use priostack_acn::{Client, Object};
//!
//! # fn main() -> Result<(), priostack_acn::Error> {
//! let acn = Client::new()?;
//! acn.register("my-agent")?;                    // token captured internally
//! acn.connect()?;                               // session id captured internally
//! let space = acn.create_space("prod-memory", &[])?;
//! acn.store(&space.space_id, &[
//!     Object::declaration("Refunds over $500 need manager approval."),
//! ])?;
//! let hits = acn.fetch(&space.space_id, "refund", 0)?;
//! for content in hits.contents() {
//!     println!("{content}");
//! }
//! acn.disconnect()?;
//! # Ok(())
//! # }
//! ```

mod client;
mod error;
mod types;

pub use client::{Client, ClientBuilder};
pub use error::{Error, Outcome, Result};
pub use types::{
    ConnectResult, FetchResult, GrantResult, Object, ObjectType, RegisterResult, SpaceResult,
    StoreResult,
};

/// Canonical MCP endpoint (Streamable HTTP). `https://priostack.com/acn/rpc` is
/// a working alias.
pub const DEFAULT_ENDPOINT: &str = "https://priostack.com/mcp";

/// The `type` values the `store` tool accepts. See [`ObjectType`].
pub const STORE_KINDS: [&str; 3] = ["declaration", "observation", "measurement"];

/// The rights [`Client::grant_access`] confers when none are specified.
pub const DEFAULT_GRANT_RIGHTS: [&str; 2] = ["read", "quote"];
