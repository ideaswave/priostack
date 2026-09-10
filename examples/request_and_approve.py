"""Consumer-initiated access: request -> approve -> read.

Instead of the owner pushing a grant, the consumer *asks* for access to a space
and the owner approves it. This is the handshake to use when the consumer knows
which space it needs but the owner has not pre-authorized it.

Flow:
  1. owner publishes a space so the consumer can discover it
  2. consumer discovers the space and requests `read`
  3. owner lists pending requests and approves one
  4. consumer reconnects and reads
"""

from priostack import ACNClient


def main() -> None:
    # --- Owner: create + seed + publish a space so it is discoverable ---
    owner = ACNClient()
    owner.register(display_name="kb-owner")
    owner.connect()
    space = owner.create_space("public-kb", default_rights=["read", "quote"])
    owner.store(
        space.space_id,
        objects=[{"content": "The API rate limit is 100 requests/minute.", "type": "declaration"}],
    )
    owner.publish(space.space_id, visibility="public")
    print(f"owner published {space.space_id}")

    # --- Consumer: discover the space, then request read access ---
    consumer = ACNClient()
    consumer.register(display_name="kb-consumer")
    consumer.connect()

    listings = consumer.discover(query="public-kb")
    print(f"consumer discovered {len(listings)} public space(s)")

    consumer.request_access(
        space.space_id, rights=["read"], reason="need the API rate limit"
    )
    print("consumer requested read access")

    # --- Owner: review pending requests and approve ---
    pending = owner.list_requests()
    print(f"owner sees {len(pending)} pending request(s)")
    for req in pending:
        grant = owner.approve_request(req["id"], rights=["read"])
        print(f"owner approved request {req['id']} -> {grant.capability_ref}")

    # --- Consumer: reconnect to apply the grant, then read ---
    consumer.connect()
    hits = consumer.fetch(space.space_id, query="rate limit")
    print("consumer now reads:")
    for content in hits.contents():
        print(f"  - {content}")

    owner.close()
    consumer.close()


if __name__ == "__main__":
    main()
