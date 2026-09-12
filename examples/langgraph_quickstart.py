"""LangGraph quickstart: a graph whose memory outlives the run.

A LangGraph checkpointer keeps state *within* a run (and, with a persistent one, within one
process's store). The ACN keeps it **on the network**: the graph recalls what previous runs stored,
across processes and machines, and another agent entirely can be granted access to the same space.

The graph here is three nodes — recall → answer → remember — and the quickstart runs it twice, so
the second run visibly answers from what the first one wrote. Then a reviewer agent, with its own
identity, is granted `read` on the space and reads the same context back.

The ACN half is real and runs on its own; the LangGraph half is optional.

    pip install priostack
    python examples/langgraph_quickstart.py

    # with the graph actually compiled and run:
    pip install priostack langgraph
    python examples/langgraph_quickstart.py

Point it somewhere else without editing the file:

    export PRIOSTACK_ENDPOINT=http://127.0.0.1:8091/rpc
"""

from __future__ import annotations

from typing import Any, Dict, List

from priostack import ACNClient

QUESTION = "deployment"
TURNS = [
    "Deployment is gated on the e2e suite passing at 90% or better.",
    "A deployment below that gate is rolled back to the previous tag automatically.",
]


class ACNMemory:
    """The graph's long-term memory: one ACN space, reached by one registered agent."""

    def __init__(self, display_name: str, space_name: str) -> None:
        self.acn = ACNClient()
        self.agent_id = self.acn.register(display_name=display_name).agent_id
        self.acn.connect()
        # An existing space is reused by id in a real deployment (persist it next to the token);
        # a quickstart makes a fresh one every run.
        self.space_id = self.acn.create_space(space_name, default_rights=["read", "quote"]).space_id

    def recall(self, topic: str, limit: int = 5) -> List[str]:
        return self.acn.fetch(self.space_id, query=topic, limit=limit).contents()

    def remember(self, fact: str) -> None:
        self.acn.store(self.space_id, objects=[{"content": fact, "type": "declaration"}])

    def close(self) -> None:
        self.acn.close()


# ── Graph nodes ─────────────────────────────────────────────────────────────────────────────────
# Each node takes the state dict and returns the keys it changed — the LangGraph contract. They are
# plain functions, so they run with or without the framework installed.


def make_nodes(memory: ACNMemory):
    def recall_node(state: Dict[str, Any]) -> Dict[str, Any]:
        """Load everything the network already knows about this question."""
        return {"recalled": memory.recall(state["question"])}

    def answer_node(state: Dict[str, Any]) -> Dict[str, Any]:
        """Compose an answer from recalled context. An LLM call would go here."""
        recalled = state.get("recalled") or []
        answer = (
            "Known: " + "; ".join(recalled)
            if recalled
            else "Nothing known about that yet — this is the first run."
        )
        return {"answer": answer}

    def remember_node(state: Dict[str, Any]) -> Dict[str, Any]:
        """Write this turn's new fact back to the network, for every later run and agent."""
        if state.get("new_fact"):
            memory.remember(state["new_fact"])
        return {}

    return recall_node, answer_node, remember_node


def build_graph(memory: ACNMemory):
    """Compile the LangGraph state graph, or return None if langgraph is not installed."""
    try:
        from langgraph.graph import END, START, StateGraph
    except ImportError:
        return None

    try:                                       # typed state, when typing_extensions is present
        from typing_extensions import TypedDict

        class State(TypedDict, total=False):
            question: str
            new_fact: str
            recalled: List[str]
            answer: str

        schema: Any = State
    except ImportError:
        schema = dict

    recall_node, answer_node, remember_node = make_nodes(memory)
    g = StateGraph(schema)
    g.add_node("recall", recall_node)
    g.add_node("answer", answer_node)
    g.add_node("remember", remember_node)
    g.add_edge(START, "recall")
    g.add_edge("recall", "answer")
    g.add_edge("answer", "remember")
    g.add_edge("remember", END)
    return g.compile()


def run_once(graph, memory: ACNMemory, question: str, new_fact: str) -> Dict[str, Any]:
    """One graph run — through LangGraph when it is installed, otherwise node by node."""
    state: Dict[str, Any] = {"question": question, "new_fact": new_fact}
    if graph is not None:
        return graph.invoke(state)
    recall_node, answer_node, remember_node = make_nodes(memory)
    state.update(recall_node(state))
    state.update(answer_node(state))
    state.update(remember_node(state))
    return state


def main() -> None:
    memory = ACNMemory("langgraph-agent", "langgraph-memory")
    print(f"1. agent {memory.agent_id} owns space {memory.space_id}")

    graph = build_graph(memory)
    print(
        "2. graph:",
        "compiled with langgraph" if graph else "langgraph absent — running the nodes directly",
    )

    for i, fact in enumerate(TURNS, start=1):
        out = run_once(graph, memory, QUESTION, fact)
        print(f"3.{i} run {i} recalled {len(out.get('recalled') or [])} · {out['answer']}")

    # ── The memory is not locked to this graph ──────────────────────────────────────────────
    # A reviewer agent — its own registration, its own token — is granted read on the same space.
    reviewer = ACNClient()
    reviewer_id = reviewer.register(display_name="langgraph-reviewer").agent_id
    reviewer.connect()
    grant = memory.acn.grant_access(memory.space_id, reviewer_id, rights=["read"])
    reviewer.connect()                                       # reconnect to apply the grant
    hits = reviewer.fetch(memory.space_id, query=QUESTION)
    print(
        f"4. reviewer {reviewer_id} granted {grant.effective_rights}, "
        f"reads {hits.matched} object(s):"
    )
    for content in hits.contents():
        print(f"     - {content}")

    reviewer.close()
    memory.close()


if __name__ == "__main__":
    main()
