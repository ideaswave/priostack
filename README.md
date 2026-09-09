# ⚡ Priostack Agent Context Network (ACN)

> **Zero-setup, model-agnostic memory orchestration & multi-agent context sharing via MCP.**

[![PyPI version](https://img.shields.io/pypi/v/priostack.svg)](https://pypi.org/project/priostack/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Priostack ACN decouples long-term memory from LLM vendor lock-in, treating persistent state as a **network resource**. Powered by the **Model Context Protocol (MCP)** over JSON-RPC, it allows AI agents to self-register, manage isolated context spaces, and securely exchange knowledge via scoped capability grants.

---

## 🔥 Key Architectural Features

- 🤖 **Zero-Setup Agent Onboarding**: Agents self-register via API (`noetic.register`). No dashboards, UIs, or credit cards required.
- 🌐 **Model-Agnostic Context**: Decouple agent memory from underlying LLMs (OpenAI, Anthropic, local models).
- 🤝 **Multi-Agent Context Sharing**: Grant or request explicit capabilities (`read`, `quote`, `fact_use`, `mutate`) between independent agents using `noetic.grant`.
- 🧠 **Fact Typology**: Differentiate strictly between *observations* (measured facts) and *declarations* (rules/hypotheses) to minimize hallucinations.
- 🔌 **Native MCP Integration**: Hook directly into Claude Desktop, Cursor, LangChain, CrewAI, or custom swarms.

---

## 🚀 Quickstart (Python)

### 1. Installation

```bash
pip install priostack
```

### 2. Basic Memory Workflow

```python
from priostack import ACNClient

# Initialize client
acn = ACNClient()

# Self-register agent & establish session
token = acn.register(display_name="primary-agent")
session_id = acn.connect(token=token)

# Create an isolated memory space
space = acn.create_space(display_name="production-rules")

# Persist structured context
acn.store(
    space_id="space-1",
    objects=[
        {"content": "Refunds over $500 require manager approval.", "type": "declaration"},
        {"content": "Customer ID #402 initiated export pipeline.", "type": "observation"}
    ]
)
```

---

## 🤝 Multi-Agent Context Sharing Example

Agents can securely share context spaces without exposing full system privileges:

```python
from priostack import ACNClient

# --- AGENT 1: Master Agent (Context Owner) ---
master = ACNClient()
master_token = master.register(display_name="master-agent")
master.connect(token=master_token)

# Create space & store data
space = master.create_space(display_name="shared-knowledge")
master.store(space_id="space-1", objects=[
    {"content": "Global API rate limit set to 100 req/min.", "type": "declaration"}
])

# --- AGENT 2: Worker Agent (Consumer) ---
worker = ACNClient()
worker_token = worker.register(display_name="worker-agent")
worker_conn = worker.connect(token=worker_token)
worker_id = worker_conn.get("data", {}).get("resolvedAccount")

# --- GRANT CAPABILITIES ---
# Master agent grants read and quote permissions to worker
master.grant_access(
    space_id="space-1",
    subject_principal=worker_id,
    rights=["read", "quote"],
    world_mutation="read"
)

# Worker reconnects to sync new permissions
worker.connect(token=worker_token)
```

---

## 🛠️ MCP Integration (Cursor / Claude Desktop)

Add Priostack ACN directly to your `mcpServers` configuration:

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

Endpoint: `https://priostack.com/acn/rpc`

| Method | Description | Key Parameters |
| :--- | :--- | :--- |
| `noetic.register` | Registers a new agent autonomously | `displayName` |
| `noetic.connect` | Establishes an active session | `token`, `maxResponseTokens` |
| `noetic.create_space` | Instantiates an isolated context space | `sessionId`, `displayName`, `defaultRights` |
| `noetic.store` | Persists observations/declarations | `sessionId`, `space`, `objects` |
| `noetic.grant` | Grants scoped access to another agent | `sessionId`, `space`, `subjectPrincipal`, `rights`, `worldMutation` |
| `noetic.request_access` | Requests access to a remote space | `sessionId`, `space`, `requestedRights` |

---

## 📄 License

Distributed under the MIT License. See `LICENSE` for more information.
