"""Shared memory for a CrewAI crew: agents read and write a common ACN space.

Each CrewAI agent can be given the same two ACN-backed tools, so knowledge one
agent records is available to the others (and to future runs). As with the
LangChain example, the ACN calls are real; the crew wiring is illustrative.

    pip install priostack crewai
    export ANTHROPIC_API_KEY=sk-ant-...   # or your configured CrewAI LLM
    python examples/crewai_memory.py
"""

import os

from priostack import ACNClient

acn = ACNClient()
acn.register(display_name="crewai-crew")
acn.connect()
SPACE_ID = acn.create_space(display_name="crew-shared-memory").space_id


def remember(fact: str) -> str:
    acn.store(SPACE_ID, objects=[{"content": fact, "type": "declaration"}])
    return f"Recorded: {fact!r}"


def recall(topic: str) -> str:
    hits = acn.fetch(SPACE_ID, query=topic, limit=5)
    return "\n".join(hits.contents()) or "Nothing recorded yet."


def build_tools():
    """Wrap the ACN calls as CrewAI tools."""
    from crewai.tools import tool

    @tool("Remember Fact")
    def remember_tool(fact: str) -> str:
        """Persist a fact to the crew's shared long-term memory."""
        return remember(fact)

    @tool("Recall Fact")
    def recall_tool(topic: str) -> str:
        """Recall facts related to a topic from the crew's shared memory."""
        return recall(topic)

    return [remember_tool, recall_tool]


def main() -> None:
    tools = build_tools()

    if not os.environ.get("ANTHROPIC_API_KEY") and not os.environ.get("OPENAI_API_KEY"):
        # No LLM configured: exercise the shared memory directly.
        print(remember("The launch date is 2026-10-01."))
        print(recall("launch"))
        return

    from crewai import Agent, Crew, Task

    researcher = Agent(
        role="Researcher",
        goal="Record findings to shared memory",
        backstory="You investigate and write durable notes for the crew.",
        tools=tools,
    )
    writer = Agent(
        role="Writer",
        goal="Recall shared findings and summarize them",
        backstory="You read the crew's shared memory and produce summaries.",
        tools=tools,
    )
    crew = Crew(
        agents=[researcher, writer],
        tasks=[
            Task(description="Record: the launch date is 2026-10-01.", agent=researcher,
                 expected_output="confirmation"),
            Task(description="Recall the launch date and state it.", agent=writer,
                 expected_output="the launch date"),
        ],
    )
    print(crew.kickoff())


if __name__ == "__main__":
    main()
