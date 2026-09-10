/**
 * Quickstart: register an agent, store facts, and read them back.
 *
 * It talks to the live ACN and registers a throwaway agent. Build and run it:
 *
 *   npm install
 *   npm run build
 *   node dist/examples/quickstart.js
 *
 * The live calls live inside `main()`, guarded below, so importing this file
 * does not fire any network requests.
 */

import { pathToFileURL } from "node:url";

import { ACNClient } from "../src/index.js";

async function main(): Promise<void> {
  // Keep one client for the agent's lifetime; `close()` ends the session.
  const acn = new ACNClient();
  try {
    // 1. Self-register (no API key, no dashboard). The token is captured on the
    //    client and returned so you can persist it for next time.
    const reg = await acn.register("typescript-sdk-smoke");
    console.log(`1. registered agent ${reg.agentId} (tier ${reg.tier})`);
    console.log(`   token (store this, shown once): ${reg.token}`);

    // 2. Open a session. The session id is captured internally.
    const conn = await acn.connect();
    console.log(`2. session ${conn.sessionId} | capabilities ${conn.grantedCapabilities.join(", ")}`);

    // 3. Create an isolated memory space. Use the RETURNED id for writes.
    const space = await acn.createSpace("prod-agent-memory");
    console.log(`3. created space ${space.spaceId}`);

    // 4. Persist typed facts. `type` must be declaration | observation | measurement.
    const stored = await acn.store(space.spaceId, [
      { content: "User approved execution workflow #402.", type: "declaration" },
      { content: "Export pipeline latency was 1.8s at 14:02 UTC.", type: "observation" },
    ]);
    console.log(`4. stored ${stored.count} objects`);

    // 5. Read them back. `query` is a case-insensitive substring filter.
    const hits = await acn.fetch(space.spaceId, { query: "workflow" });
    console.log(`5. fetched ${hits.matched}/${hits.total} (viewport ${hits.returnedTokens} tokens):`);
    for (const content of hits.contents) {
      console.log(`     - ${content}`);
    }
  } finally {
    await acn.close();
  }
}

// Only run when executed directly (`node dist/examples/quickstart.js`), not on import.
const entry = process.argv[1];
if (entry && import.meta.url === pathToFileURL(entry).href) {
  main().catch((err) => {
    console.error(err);
    process.exitCode = 1;
  });
}

export { main };
