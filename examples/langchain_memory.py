"""Give a LangChain agent durable, cross-session memory backed by the ACN.

Two tools are exposed to the agent: one to persist a fact, one to recall facts.
The ACN calls are the load-bearing part and use the real client signatures; the
agent wiring is illustrative and tracks the modern LangChain tool-calling API.

    pip install priostack langchain langchain-anthropic
    export ANTHROPIC_API_KEY=sk-ant-...
    python examples/langchain_memory.py
"""

import os

from priostack import ACNClient

# One shared ACN session for the process. In a real app you would persist the
# token (reg.token) and the space id and reconnect on the next run.
acn = ACNClient()
acn.register(display_name="langchain-agent")
acn.connect()
_space = acn.create_space(display_name="langchain-memory")
SPACE_ID = _space.space_id


def _save(fact: str) -> str:
    acn.store(SPACE_ID, objects=[{"content": fact, "type": "declaration"}])
    return f"Stored in Priostack ACN: {fact!r}"


def _recall(topic: str) -> str:
    hits = acn.fetch(SPACE_ID, query=topic, limit=5)
    if not hits.objects:
        return "No matching memory found."
    return "\n".join(f"- {c}" for c in hits.contents())


def build_tools():
    """Wrap the ACN calls as LangChain tools."""
    from langchain_core.tools import tool

    @tool
    def save_memory(fact: str) -> str:
        """Persist an important fact or user preference for future sessions."""
        return _save(fact)

    @tool
    def recall_memory(topic: str) -> str:
        """Recall previously stored facts related to a topic (substring match)."""
        return _recall(topic)

    return [save_memory, recall_memory]


def main() -> None:
    tools = build_tools()

    if not os.environ.get("ANTHROPIC_API_KEY"):
        # No key: demonstrate the tools directly so the example still runs.
        print(_save("The user's primary language is Python."))
        print(_recall("language"))
        return

    from langchain.agents import AgentExecutor, create_tool_calling_agent
    from langchain_anthropic import ChatAnthropic
    from langchain_core.prompts import ChatPromptTemplate

    llm = ChatAnthropic(model="claude-opus-5", temperature=0)
    prompt = ChatPromptTemplate.from_messages([
        ("system", "You are a helpful assistant with persistent memory. "
                   "Use save_memory to remember facts and recall_memory to look them up."),
        ("human", "{input}"),
        ("placeholder", "{agent_scratchpad}"),
    ])
    agent = create_tool_calling_agent(llm, tools, prompt)
    executor = AgentExecutor(agent=agent, tools=tools, verbose=True)

    executor.invoke({"input": "Remember that the user's primary programming language is Python."})
    print(executor.invoke({"input": "What is the user's primary programming language?"})["output"])


if __name__ == "__main__":
    main()
