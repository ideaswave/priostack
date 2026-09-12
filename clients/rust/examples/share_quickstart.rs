//! Sharing quickstart: two agents, one space, an explicit grant.
//!
//! `quickstart.rs` shows one agent keeping its own memory. This is the other half, and the reason
//! the network exists: an owner agent stores knowledge, a second agent registers separately, and
//! the owner grants it scoped `read` + `quote` on that one space. Nothing is shared until the grant
//! exists, the grant names the grantee's agent id, and it can be revoked in one call.
//!
//! ```text
//! cargo run --example share_quickstart
//! ```
//!
//! Optional environment override:
//! * `PRIOSTACK_ENDPOINT` — RPC endpoint (default <https://priostack.com/mcp>)

use std::error::Error as StdError;

use priostack_acn::{Client, Error, Object, Outcome, DEFAULT_ENDPOINT};

/// Register one agent and open its session.
fn onboard(endpoint: &str, display_name: &str) -> Result<(Client, String), Box<dyn StdError>> {
    let acn = Client::builder().endpoint(endpoint.to_string()).build()?;
    let reg = acn.register(display_name)?;
    acn.connect()?;
    println!("  {display_name}: agent {}", reg.agent_id);
    Ok((acn, reg.agent_id))
}

/// Whether this client can reach the space at all. A space it holds no capability on answers
/// not-found — the same answer a space that does not exist gives: the network does not confirm the
/// existence of context you were never granted.
fn can_read(acn: &Client, space_id: &str) -> Result<bool, Box<dyn StdError>> {
    match acn.fetch(space_id, "", 0) {
        Ok(_) => Ok(true),
        Err(Error::Tool { outcome: Outcome::NotFound, .. }) => Ok(false),
        Err(err) => Err(Box::new(err)),
    }
}

fn main() -> Result<(), Box<dyn StdError>> {
    let endpoint =
        std::env::var("PRIOSTACK_ENDPOINT").unwrap_or_else(|_| DEFAULT_ENDPOINT.to_string());

    println!("1. onboarding two agents");
    let (owner, _) = onboard(&endpoint, "rust-owner")?;
    let (worker, worker_id) = onboard(&endpoint, "rust-worker")?;

    // The rights passed here are the ceiling of what this space may ever offer. They grant nothing
    // by themselves: until there is a grant, only the owner can read it.
    let space = owner.create_space("shift-handover", &["read", "quote"])?;
    println!("2. owner created space {}", space.space_id);

    let stored = owner.store(
        &space.space_id,
        &[
            Object::observation("Night shift found a stuck consumer on queue orders-v2."),
            Object::declaration("Restarting the consumer requires a change ticket after 22:00."),
        ],
    )?;
    println!("3. owner stored {} object(s)", stored.count());

    println!(
        "{}",
        if can_read(&worker, &space.space_id)? {
            "4. worker could read the space BEFORE a grant — that would be a bug"
        } else {
            "4. worker cannot see the space yet (as expected)"
        }
    );

    // The subject of a grant is the grantee's AGENT ID, not its display name or its account.
    let grant = owner.grant_access(&space.space_id, &worker_id, &["read", "quote"], None)?;
    println!(
        "5. granted {} ({})",
        grant.effective_rights.join(", "),
        grant.capability_ref
    );

    // The grantee reconnects so its session picks up the widened scope.
    worker.connect()?;
    let hits = worker.fetch(&space.space_id, "consumer", 0)?;
    println!("6. worker reads {} of {} object(s):", hits.matched, hits.total);
    for content in hits.contents() {
        println!("     - {content}");
    }

    // Revoking is immediate and forward-only: the worker keeps nothing it has already read, and
    // loses the space on its next session.
    owner.revoke_access(&grant.capability_ref)?;
    worker.connect()?;
    println!(
        "{}",
        if can_read(&worker, &space.space_id)? {
            "7. worker still reads the space after revoke — that would be a bug"
        } else {
            "7. grant revoked — the worker cannot read the space any more"
        }
    );

    worker.disconnect()?;
    owner.disconnect()?;
    Ok(())
}
