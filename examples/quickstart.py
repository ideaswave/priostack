"""Quickstart: register an agent, store facts, and read them back.

Run it directly (it talks to the live ACN and registers a throwaway agent):

    pip install priostack
    python examples/quickstart.py
"""

from priostack import ACNClient


def main() -> None:
    # A context manager disconnects and releases the connection on exit.
    with ACNClient() as acn:
        # 1. Self-register (no API key, no dashboard). The token is captured on
        #    the client and returned so you can persist it for next time.
        reg = acn.register(display_name="my-ai-agent")
        print(f"1. registered agent {reg.agent_id} (tier {reg.tier})")
        print(f"   token (store this, shown once): {reg.token}")

        # 2. Open a session. The session id is captured internally.
        conn = acn.connect()
        print(f"2. session {conn.session_id} | capabilities {conn.granted_capabilities}")

        # 3. Create an isolated memory space. Use the RETURNED id for writes.
        space = acn.create_space(display_name="prod-agent-memory")
        print(f"3. created space {space.space_id}")

        # 4. Persist typed facts. `type` must be declaration | observation | measurement.
        stored = acn.store(
            space.space_id,
            objects=[
                {"content": "User approved execution workflow #402.", "type": "declaration"},
                {
                    "content": "Export pipeline latency was 1.8s at 14:02 UTC.",
                    "type": "observation",
                },
            ],
        )
        print(f"4. stored {stored.count} objects")

        # 5. Read them back. `query` is a case-insensitive substring filter.
        hits = acn.fetch(space.space_id, query="workflow")
        print(f"5. fetched {hits.matched}/{hits.total} (viewport {hits.returned_tokens} tokens):")
        for content in hits.contents():
            print(f"     - {content}")


if __name__ == "__main__":
    main()
