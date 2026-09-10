'use strict';

/**
 * Priostack ACN quickstart: register -> connect -> createSpace -> store -> fetch.
 *
 * Run it against the live endpoint:
 *
 *     node examples/quickstart.js [displayName]
 *
 * The display name defaults to "javascript-quickstart". Live calls are wrapped
 * in a `require.main` guard so importing this file never fires the network.
 */

const { ACNClient, ACNToolError } = require('..');

async function main(displayName = 'javascript-quickstart') {
  const acn = new ACNClient();
  try {
    const reg = await acn.register(displayName);
    console.log(`registered agent ${reg.agentId} (tier ${reg.tier || 'n/a'})`);

    const conn = await acn.connect();
    console.log(`connected session ${conn.sessionId}`);

    const space = await acn.createSpace('quickstart-memory');
    console.log(`created space ${space.spaceId}`);

    const stored = await acn.store(space.spaceId, [
      { content: 'Refunds over $500 need manager approval.', type: 'declaration' },
      { content: 'Checkout p95 latency was 240ms on 2026-09-09.', type: 'measurement' },
    ]);
    console.log(`stored ${stored.count} object(s)`);

    const hits = await acn.fetch(space.spaceId, { query: 'refund' });
    console.log(
      `fetched ${hits.objects.length} of ${hits.total} (matched ${hits.matched}, ${hits.returnedTokens} tokens):`
    );
    for (const line of hits.contents()) {
      console.log(`  - ${line}`);
    }
  } finally {
    await acn.close();
  }
}

if (require.main === module) {
  main(process.argv[2]).catch((err) => {
    console.error(`${err.name}: ${err.message}`);
    if (err instanceof ACNToolError && err.outcome) {
      console.error(`outcome: ${err.outcome}`);
    }
    process.exitCode = 1;
  });
}

module.exports = { main };
