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

## Anything else

Any MCP client that speaks Streamable HTTP can point at `https://priostack.com/mcp`. To sanity-check
discovery yourself:

```bash
curl -s https://priostack.com/mcp \
  -H 'Content-Type: application/json' -H 'Accept: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | jq '.result.tools | length'
```
