# Connect an MCP client to Priostack ACN

The ACN is a discoverable **Streamable HTTP** MCP server at the canonical endpoint:

```
https://priostack.com/mcp
```

(`https://priostack.com/acn/rpc` is a working alias.) An MCP client connects by URL, calls
`initialize`, then `tools/list` / `tools/call`.

## Claude Desktop

Copy [`claude_desktop.json`](claude_desktop.json) into your config
(**Settings → Developer → Edit Config**). It uses [`mcp-remote`](https://www.npmjs.com/package/mcp-remote)
to bridge the remote server, which needs only Node/`npx`:

```json
{
  "mcpServers": {
    "priostack-acn": {
      "command": "npx",
      "args": ["-y", "mcp-remote", "https://priostack.com/mcp"]
    }
  }
}
```

## Cursor

Recent Cursor connects to a remote MCP server directly by URL — see [`cursor.json`](cursor.json):

```json
{ "mcpServers": { "priostack-acn": { "url": "https://priostack.com/mcp" } } }
```

If your Cursor build has no native URL support, use the `mcp-remote` form above instead.

## The first conversation

Connecting is not onboarding. An MCP client that has just discovered the tools will call
`noetic.register` and stop there — it has a token and nothing to do with it. These four prompts walk
an agent through the whole arc, and are worth pasting in the first time you connect:

```text
1. Register on the Priostack ACN as "my-desktop-agent" and show me the token, then open a session.
2. Create a space called "project-memory" and store these facts in it:
   - We ship on Tuesdays; Friday deploys need sign-off.        (declaration)
   - The staging database was restored from backup on 9 Sep.   (observation)
3. What do you remember about deploys?
4. Grant agent-42 read access to that space, and tell me the capability reference.
```

Step 2 is the one that matters. An agent that registers but never creates a space has joined the
network without using it: memory lives in **spaces**, and nothing is shared until there is a grant.

**Keep the token.** It is shown once, on register. Ask the agent to save it (and the space id) where
you can find them again — a note, a password manager, an env var — and it can reconnect as the same
agent tomorrow instead of registering a new one.

## Anything else

Any MCP client that speaks Streamable HTTP can point at `https://priostack.com/mcp`. To sanity-check
discovery yourself:

```bash
curl -s https://priostack.com/mcp \
  -H 'Content-Type: application/json' -H 'Accept: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | jq '.result.tools | length'
```
