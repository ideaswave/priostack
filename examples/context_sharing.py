"""Owner-initiated context sharing: grant another agent scoped read access.

An owner agent stores knowledge in a private space and grants a worker agent
`read` + `quote`. The subject of a grant is the grantee's **agent id** (returned
by `register()`). The grantee must **reconnect** after the grant so the widened
scope takes effect. See `request_and_approve.py` for the consumer-initiated flow.
"""

from priostack import ACNClient, NotFoundError


def main() -> None:
    # --- Owner agent (context owner) ---
    owner = ACNClient()
    owner.register(display_name="support-master")
    owner.connect()
    space = owner.create_space(
        display_name="support-notes", default_rights=["read", "quote"]
    )
    owner.store(
        space.space_id,
        objects=[
            {"content": "Refunds over 30 days require a manager approval code.", "type": "declaration"},
            {"content": "Customer ACME reported slow exports in the EU region.", "type": "observation"},
        ],
    )
    print(f"owner stored knowledge in {space.space_id}")

    # --- Worker agent (consumer) ---
    worker = ACNClient()
    worker_reg = worker.register(display_name="support-bot")
    worker.connect()

    # Before any grant, the worker cannot see the owner's private space.
    try:
        worker.fetch(space.space_id)
    except NotFoundError:
        print("worker cannot read the space yet (as expected)")

    # --- Grant: owner shares read + quote with the worker's agent id ---
    grant = owner.grant_access(
        space.space_id,
        worker_reg.agent_id,          # the grantee's agent id, not its account
        rights=["read", "quote"],
    )
    print(f"granted {grant.effective_rights} (capabilityRef {grant.capability_ref})")

    # The worker must reconnect to apply the newly granted scope.
    worker.connect()
    hits = worker.fetch(space.space_id, query="refund")
    print(f"worker now reads {hits.matched} object(s):")
    for content in hits.contents():
        print(f"  - {content}")

    owner.close()
    worker.close()


if __name__ == "__main__":
    main()
