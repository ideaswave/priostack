//! Quickstart: register -> connect -> create_space -> store -> fetch.
//!
//! All live network calls run inside `main`, so building the library does not
//! fire any requests. Run it against the live endpoint with:
//!
//! ```text
//! cargo run --example quickstart
//! ```
//!
//! Optional environment overrides:
//! * `PRIOSTACK_ENDPOINT`      — RPC endpoint (default https://priostack.com/mcp)
//! * `PRIOSTACK_DISPLAY_NAME`  — agent display name (default rust-sdk-quickstart)

use std::error::Error;

use priostack_acn::{Client, Object, DEFAULT_ENDPOINT};

fn main() -> Result<(), Box<dyn Error>> {
    let endpoint = std::env::var("PRIOSTACK_ENDPOINT").unwrap_or_else(|_| DEFAULT_ENDPOINT.to_string());
    let display_name =
        std::env::var("PRIOSTACK_DISPLAY_NAME").unwrap_or_else(|_| "rust-sdk-quickstart".to_string());

    let acn = Client::builder().endpoint(endpoint).build()?;

    let reg = acn.register(&display_name)?;
    println!(
        "registered agent {} (account {}, tier {})",
        reg.agent_id, reg.account_id, reg.tier
    );

    let conn = acn.connect()?;
    println!(
        "connected session {} (account {})",
        conn.session_id, conn.resolved_account
    );

    let space = acn.create_space("prod-memory", &[])?;
    println!("created space {}", space.space_id);

    let stored = acn.store(
        &space.space_id,
        &[
            Object::declaration("Refunds over $500 need manager approval."),
            Object::observation("Customer 4417 asked about EU shipping twice this week."),
        ],
    )?;
    println!("stored {} objects", stored.count());

    let hits = acn.fetch(&space.space_id, "refund", 0)?;
    println!(
        "fetched {} of {} objects (query = \"refund\"):",
        hits.objects.len(),
        hits.total
    );
    for content in hits.contents() {
        println!("  - {content}");
    }

    acn.disconnect()?;
    println!("disconnected");

    Ok(())
}
