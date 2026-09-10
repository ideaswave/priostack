"""Lifecycle of a shared capability: grant -> use -> revoke, plus token rotation.

Revocation is immediate and forward-only: once revoked, the grantee's next
reconnect no longer sees the space. Token rotation mints a fresh bearer token
and retires the old one (existing live sessions keep working).
"""

from priostack import ACNClient, NotFoundError


def main() -> None:
    owner = ACNClient()
    owner.register(display_name="rotate-owner")
    owner.connect()
    space = owner.create_space("secrets-lite", default_rights=["read"])
    owner.store(space.space_id, objects=[
        {"content": "Staging DB host is db-staging.internal.", "type": "declaration"},
    ])

    worker = ACNClient()
    worker_reg = worker.register(display_name="rotate-worker")
    worker.connect()

    # Grant, then the worker reconnects and can read.
    grant = owner.grant_access(space.space_id, worker_reg.agent_id, rights=["read"])
    worker.connect()
    print("after grant, worker reads:", worker.fetch(space.space_id).contents())

    # Revoke; after the worker reconnects the space is gone for it.
    owner.revoke_access(grant.capability_ref)
    worker.connect()
    try:
        worker.fetch(space.space_id)
        print("BUG: still readable after revoke")
    except NotFoundError:
        print("after revoke, worker can no longer read (as expected)")

    # Rotate the worker's bearer token. Persist the new one; the old is retired.
    old = worker.token
    new = worker.rotate_token()
    print(f"rotated token: {old[:10]}... -> {new[:10]}...")
    # A brand-new client using the new token connects fine.
    with ACNClient(token=new) as w2:
        w2.connect()
        print("reconnected with the rotated token, session:", w2.session_id[:16])

    owner.close()
    worker.close()


if __name__ == "__main__":
    main()
