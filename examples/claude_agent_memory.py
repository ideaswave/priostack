"""A Claude agent (Anthropic SDK) with durable memory backed by the ACN.

Claude is given two tools — `remember` and `recall` — wired to a Priostack ACN
space. Because the space is durable, memory persists across process restarts and
can be shared with other agents via grants. This uses the Messages API tool-use
loop directly.

    pip install priostack anthropic
    export ANTHROPIC_API_KEY=sk-ant-...
    python examples/claude_agent_memory.py
"""

import json
import os

from priostack import ACNClient

MODEL = "claude-opus-5"

TOOLS = [
    {
        "name": "remember",
        "description": "Persist an important fact for future conversations.",
        "input_schema": {
            "type": "object",
            "properties": {"fact": {"type": "string"}},
            "required": ["fact"],
        },
    },
    {
        "name": "recall",
        "description": "Recall previously stored facts related to a topic (substring match).",
        "input_schema": {
            "type": "object",
            "properties": {"topic": {"type": "string"}},
            "required": ["topic"],
        },
    },
]


def run_tool(acn: ACNClient, space_id: str, name: str, args: dict) -> str:
    if name == "remember":
        acn.store(space_id, objects=[{"content": args["fact"], "type": "declaration"}])
        return f"stored: {args['fact']}"
    if name == "recall":
        hits = acn.fetch(space_id, query=args.get("topic", ""), limit=5)
        return "\n".join(hits.contents()) or "no matching memory"
    return f"unknown tool {name}"


def main() -> None:
    if not os.environ.get("ANTHROPIC_API_KEY"):
        print("Set ANTHROPIC_API_KEY to run this example.")
        return

    from anthropic import Anthropic

    acn = ACNClient()
    acn.register(display_name="claude-memory-agent")
    acn.connect()
    space_id = acn.create_space(display_name="claude-agent-memory").space_id

    client = Anthropic()
    messages = [{
        "role": "user",
        "content": "Remember that I deploy on Tuesdays, then tell me which day I deploy.",
    }]

    # Standard tool-use loop: keep going while Claude asks to call a tool.
    while True:
        resp = client.messages.create(
            model=MODEL, max_tokens=1024, tools=TOOLS, messages=messages
        )
        messages.append({"role": "assistant", "content": resp.content})

        if resp.stop_reason != "tool_use":
            text = "".join(b.text for b in resp.content if b.type == "text")
            print(text)
            break

        results = []
        for block in resp.content:
            if block.type == "tool_use":
                out = run_tool(acn, space_id, block.name, block.input)
                print(f"[tool] {block.name}({json.dumps(block.input)}) -> {out}")
                results.append({
                    "type": "tool_result",
                    "tool_use_id": block.id,
                    "content": out,
                })
        messages.append({"role": "user", "content": results})

    acn.close()


if __name__ == "__main__":
    main()
