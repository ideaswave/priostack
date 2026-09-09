# ⚡ Priostack Agent Context Network (ACN)

> **Zero-setup, autonomous memory orchestration for AI Agents via MCP.**

[![PyPI version](https://img.shields.io/pypi/v/priostack.svg)](https://pypi.org/project/priostack/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Priostack ACN provides AI agents with persistent long-term memory, isolated space context, and execution-state management. Powered by the **Model Context Protocol (MCP)** over JSON-RPC.

---

## 🔥 Features

- 🤖 **Zero-Setup Agent Onboarding**: Agents register themselves via API without dashboards or credit cards.
- 🧠 **Structured Context Spaces**: Isolate memories, rules, and state across different agent executions.
- 🔌 **Native MCP Protocol**: Seamlessly hooks into Claude Desktop, Cursor, LangChain, CrewAI, and LlamaIndex.
- ⚡ **Sub-10ms Context Injection**: Pure JSON-RPC API endpoint for maximum execution speed.

---

## 🚀 Quickstart (Python)

### 1. Installation

```bash
pip install priostack
```

### 2. Connect Your Agent in 4 Lines

```python
from priostack import ACNClient

# Initialize Client
acn = ACNClient()

# Self-register agent & retrieve ACN Token
token = acn.register(display_name="my-first-agent")

# Connect session
session_id = acn.connect(token=token)

# Store persistent context
acn.create_space(display_name="global-memory")
acn.store(space_id="global-memory", content="Agent state initialized.", object_type="declaration")
```

---

## 🛠️ MCP Integration (Cursor / Claude Desktop)

Add Priostack ACN directly to your `mcpServers` config:

```json
{
  "mcpServers": {
    "priostack-acn": {
      "command": "npx",
      "args": [
        "-y",
        "@modelcontextprotocol/server-fetch",
        "https://priostack.com/acn/rpc"
      ]
    }
  }
}
```

---

## 📖 API Reference (JSON-RPC)

All interactions are routed through `https://priostack.com/acn/rpc`:

| Method | Description | Primary Arguments |
| :--- | :--- | :--- |
| `noetic.register` | Registers a new agent autonomously | `displayName` |
| `noetic.connect` | Creates an active session for an agent | `token`, `maxResponseTokens` |
| `noetic.create_space` | Instantiates a memory partition | `sessionId`, `displayName` |
| `noetic.store` | Persists a memory object | `sessionId`, `space`, `objects` |

---

## 📄 License

Distributed under the MIT License.
