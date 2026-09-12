"""CrewAI quickstart: a crew whose members share context through the ACN.

Every agent in the crew gets its **own ACN identity** — its own registration, its own bearer token,
its own view of the network. The researcher owns a space and writes findings into it; the writer is
granted scoped `read` + `quote` on that space and reads them back. That is the whole point of the
network: not one shared API key with one shared memory blob, but separate agents with explicit,
revocable access to each other's context.

The ACN half is real and runs on its own. The CrewAI half is optional: with `crewai` installed and
an LLM configured, the same two functions are handed to the crew as tools.

    pip install priostack
    python examples/crewai_quickstart.py

    # with the crew actually running:
    pip install priostack crewai
    export OPENAI_API_KEY=sk-...          # or ANTHROPIC_API_KEY, per your CrewAI config
    python examples/crewai_quickstart.py

Point it somewhere else (a self-hosted node, or a local one) without editing the file:

    export PRIOSTACK_ENDPOINT=http://127.0.0.1:8091/rpc
"""

from __future__ import annotations

import os

from priostack import ACNClient

FINDINGS = [
    {
        "content": "Industrial inspection cameras: 3 incumbents hold 71% of EU market share.",
        "type": "observation",
    },
    {
        "content": "Autonomous inspection is quoted per inspected metre, not per camera.",
        "type": "declaration",
    },
    {
        "content": "Pilot-to-contract conversion in this segment averaged 34% in 2025.",
        "type": "measurement",
    },
]


def onboard(display_name: str) -> tuple[ACNClient, str]:
    """Register one crew member as an agent in its own right, and open its session."""
    acn = ACNClient()
    reg = acn.register(display_name=display_name)
    acn.connect()
    print(f"  {display_name}: agent {reg.agent_id}")
    return acn, reg.agent_id


def main() -> None:
    # ── 1. Two crew members, two identities ──────────────────────────────────────────────────
    print("1. onboarding the crew")
    researcher, _ = onboard("crewai-researcher")
    writer, writer_id = onboard("crewai-writer")

    # ── 2. The researcher owns the space it writes into ──────────────────────────────────────
    # default_rights is the ceiling of what this space may ever offer to others. It grants
    # nothing by itself: until there is a grant, only the owner can read it.
    space = researcher.create_space("market-research", default_rights=["read", "quote"])
    print(f"2. researcher created space {space.space_id}")

    stored = researcher.store(space.space_id, objects=FINDINGS)
    print(f"3. researcher stored {stored.count} finding(s)")

    # ── 3. Share it with the writer, scoped and revocable ────────────────────────────────────
    # The subject of a grant is the grantee's AGENT ID (from register()), not its display name.
    grant = researcher.grant_access(space.space_id, writer_id, rights=["read", "quote"])
    print(f"4. granted {grant.effective_rights} to the writer ({grant.capability_ref})")

    # The grantee reconnects so its session picks up the widened scope.
    writer.connect()
    hits = writer.fetch(space.space_id, query="market")
    print(f"5. writer reads {hits.matched} of {hits.total} object(s) from the researcher's space:")
    for content in hits.contents():
        print(f"     - {content}")

    # ── 4. The same two operations, as CrewAI tools ──────────────────────────────────────────
    if _llm_configured():
        _run_crew(researcher, writer, space.space_id)
    else:
        print("\n(no LLM key set — skipping the crew run; the ACN calls above were real)")

    # Revoking is immediate and forward-only: the writer keeps nothing it has already read.
    # researcher.revoke_access(grant.capability_ref)

    researcher.close()
    writer.close()


def _llm_configured() -> bool:
    return any(os.environ.get(k) for k in ("OPENAI_API_KEY", "ANTHROPIC_API_KEY"))


def _run_crew(researcher: ACNClient, writer: ACNClient, space_id: str) -> None:
    """Hand each crew member a tool bound to its own ACN client."""
    try:
        from crewai import Agent, Crew, Task
        from crewai.tools import tool
    except ImportError:
        print("\n(crewai is not installed — skipping the crew run)")
        return

    @tool("Record Finding")
    def record_finding(finding: str) -> str:
        """Record a research finding in the crew's research space."""
        researcher.store(space_id, objects=[{"content": finding, "type": "observation"}])
        return f"Recorded: {finding!r}"

    @tool("Recall Findings")
    def recall_findings(topic: str) -> str:
        """Recall the researcher's findings about a topic. Read-only: this agent was granted
        `read` and `quote` on the space, and cannot write to it."""
        hits = writer.fetch(space_id, query=topic, limit=5)
        return "\n".join(hits.contents()) or "Nothing recorded on that topic yet."

    researcher_agent = Agent(
        role="Market Researcher",
        goal="Record what you find in the shared research space",
        backstory="You investigate a market and write durable notes other agents rely on.",
        tools=[record_finding],
    )
    writer_agent = Agent(
        role="Report Writer",
        goal="Recall the researcher's findings and summarise them",
        backstory="You read the research space you were granted access to and write it up.",
        tools=[recall_findings],
    )
    crew = Crew(
        agents=[researcher_agent, writer_agent],
        tasks=[
            Task(
                description=(
                    "Record this finding: EU inspection-camera buyers renew annually in Q1."
                ),
                expected_output="a confirmation that the finding was recorded",
                agent=researcher_agent,
            ),
            Task(
                description=(
                    "Recall everything known about the market and summarise it in 3 bullets."
                ),
                expected_output="three bullet points",
                agent=writer_agent,
            ),
        ],
    )

    print("\n6. running the crew")
    print(crew.kickoff())


if __name__ == "__main__":
    main()
