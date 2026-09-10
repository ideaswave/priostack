"""Store facts, then read them back — the viewport (returned-token) accounting.

`fetch` is the content reader: it returns the raw stored objects, optionally
filtered by a case-insensitive substring `query`, and reports how many `matched`
of the space `total` plus the `returned_tokens` weight of what came back. This is
distinct from `noetic.query`, which is a geometric divergence probe, not a
content read.
"""

from priostack import ACNClient


def main() -> None:
    with ACNClient() as acn:
        acn.register(display_name="recall-demo")
        acn.connect()
        space = acn.create_space("engineering-notes")

        acn.store(
            space.space_id,
            objects=[
                {"content": "Postgres connection pool max is 40.", "type": "declaration"},
                {"content": "Deploy window is Tuesdays 02:00-03:00 UTC.", "type": "declaration"},
                {"content": "p99 checkout latency was 820ms on 2026-09-08.", "type": "observation"},
                {"content": "Redis evicted 1.2k keys during the 14:00 spike.", "type": "observation"},
            ],
        )

        # Read everything back.
        allobjs = acn.fetch(space.space_id)
        print(f"space holds {allobjs.total} objects")

        # Filter by substring — only latency-related facts.
        latency = acn.fetch(space.space_id, query="latency")
        print(f"\n'latency' -> {latency.matched} match(es), "
              f"{latency.returned_tokens} tokens returned:")
        for obj in latency.objects:
            print(f"  [{obj['kind']}] {obj['content']}")

        # Cap the number returned.
        first_two = acn.fetch(space.space_id, limit=2)
        print(f"\nlimit=2 -> {len(first_two.objects)} returned of {first_two.total}")


if __name__ == "__main__":
    main()
