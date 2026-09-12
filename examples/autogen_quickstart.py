"""AutoGen quickstart: one agent asks another for access, and is approved.

The other two framework quickstarts show the owner *pushing* a grant. This one shows the other
handshake, which is the one that scales past a demo: the consumer does not know anybody, it
**discovers** a published space, **requests** the rights it needs with a reason, and the owner
**approves** — or does not. Nothing is shared until somebody agrees to share it.

Two AutoGen agents, two ACN identities:

  archivist  owns a published knowledge space and reviews incoming requests
  analyst    discovers the space, asks for `read`, and reads once approved

The ACN half is real and runs on its own. The AutoGen half is optional: with `autogen-agentchat`
installed and a model configured, the analyst's three operations are handed to an AssistantAgent as
tools and it decides when to call them.

    pip install priostack
    python examples/autogen_quickstart.py

    # with the agent actually driving the tools:
    pip install priostack autogen-agentchat autogen-ext[openai]
    export OPENAI_API_KEY=sk-...
    python examples/autogen_quickstart.py

Point it somewhere else without editing the file:

    export PRIOSTACK_ENDPOINT=http://127.0.0.1:8091/rpc
"""

from __future__ import annotations

import asyncio
import os
from typing import List

from priostack import ACNClient

KNOWLEDGE = [
    {"content": "The API rate limit is 100 requests a minute per address.", "type": "declaration"},
    {
        "content": "Exceeding it three times in a window bans the address for two hours.",
        "type": "declaration",
    },
    {"content": "Median rate-limited callers in August 2026: 4 a day.", "type": "measurement"},
]


def main() -> None:
    # ── 1. The archivist owns and publishes a space ──────────────────────────────────────────
    archivist = ACNClient()
    archivist.register(display_name="autogen-archivist")
    archivist.connect()
    space = archivist.create_space("api-policy-kb", default_rights=["read", "quote"])
    archivist.store(space.space_id, objects=KNOWLEDGE)
    # Publishing makes the space DISCOVERABLE, not readable: strangers can see that it exists and
    # ask for access. The content stays behind a grant.
    archivist.publish(space.space_id, visibility="public")
    print(
        f"1. archivist published {space.space_id} "
        f"({len(KNOWLEDGE)} objects, readable by nobody yet)"
    )

    # ── 2. The analyst arrives knowing nothing ───────────────────────────────────────────────
    analyst = ACNClient()
    analyst_id = analyst.register(display_name="autogen-analyst").agent_id
    analyst.connect()
    print(f"2. analyst {analyst_id} registered")

    tools = AnalystTools(analyst, archivist, space.space_id)

    if _model_configured():
        asyncio.run(_run_agentchat(tools))
    else:
        print("\n(no OPENAI_API_KEY set — driving the same tools directly)")
        print("3. " + tools.discover_spaces("api-policy"))
        print("4. " + tools.request_read_access(
            space.space_id, "answering a question about rate limits"))
        print("5. " + tools.read_space(space.space_id, "rate limit"))

    analyst.close()
    archivist.close()


class AnalystTools:
    """The analyst's three ACN operations, written as plain typed functions.

    AutoGen's AssistantAgent takes callables directly as tools — the type hints become the schema
    and the docstring becomes the description the model reads, so nothing here is framework glue.
    """

    def __init__(self, analyst: ACNClient, archivist: ACNClient, space_id: str) -> None:
        self.analyst = analyst
        self.archivist = archivist
        self.space_id = space_id

    def discover_spaces(self, query: str) -> str:
        """Find published context spaces on the network matching a query."""
        listings = self.analyst.discover(query=query)
        if not listings:
            return "No published space matches that."
        # A listing says what a space is and what it is willing to offer — never its contents.
        return "Found: " + "; ".join(
            "{} ({}) — owner {}, {} object(s), offers {}".format(
                item.get("displayName", "?"),
                item.get("space", "?"),
                item.get("ownerName") or item.get("owner", "?"),
                item.get("objects", 0),
                ", ".join(item.get("offeredRights") or []) or "nothing",
            )
            for item in listings
        )

    def request_read_access(self, space_id: str, reason: str) -> str:
        """Ask the owner of a space for read access, stating why it is needed."""
        self.analyst.request_access(space_id, rights=["read"], reason=reason)

        # The owner's side of the handshake. In a real deployment this is a separate process (or a
        # person): the archivist polls list_requests() and decides. Approving inside one script
        # keeps the example runnable end to end.
        pending = self.archivist.list_requests()
        if not pending:
            return "Request sent; nothing pending on the owner's side yet."
        approved: List[str] = []
        for req in pending:
            grant = self.archivist.approve_request(req["id"], rights=["read"])
            approved.append(grant.capability_ref)
        # The grantee reconnects so its session picks up the widened scope.
        self.analyst.connect()
        return f"Owner approved: {', '.join(approved)} — read access is live."

    def read_space(self, space_id: str, query: str) -> str:
        """Read the objects in a space this agent has been granted access to."""
        hits = self.analyst.fetch(space_id, query=query)
        if not hits.matched:
            return "Nothing in that space matches the query."
        return "\n".join(f"  - {line}" for line in hits.contents())


def _model_configured() -> bool:
    return bool(os.environ.get("OPENAI_API_KEY"))


async def _run_agentchat(tools: AnalystTools) -> None:
    """Hand the three operations to an AutoGen AssistantAgent and let it decide."""
    try:
        from autogen_agentchat.agents import AssistantAgent
        from autogen_ext.models.openai import OpenAIChatCompletionClient
    except ImportError:
        print("\n(autogen-agentchat is not installed — driving the same tools directly)")
        print("3. " + tools.discover_spaces("api-policy"))
        print("4. " + tools.request_read_access(
            tools.space_id, "answering a question about rate limits"))
        print("5. " + tools.read_space(tools.space_id, "rate limit"))
        return

    model = OpenAIChatCompletionClient(model=os.environ.get("OPENAI_MODEL", "gpt-4o-mini"))
    analyst = AssistantAgent(
        name="analyst",
        model_client=model,
        tools=[tools.discover_spaces, tools.request_read_access, tools.read_space],
        system_message=(
            "You answer questions from context stored on the Priostack ACN. You start with no "
            "access to anything: discover the space you need, request read access with a clear "
            "reason, then read it. Quote what you read."
        ),
    )
    result = await analyst.run(task="What is the API rate limit, and what happens if I exceed it?")
    print("\n3. agent transcript")
    for message in result.messages:
        content = getattr(message, "content", message)
        print(f"   [{getattr(message, 'source', '?')}] {content}")
    await model.close()


if __name__ == "__main__":
    main()
