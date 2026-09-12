/**
 * Sharing quickstart: two agents, one space, an explicit grant.
 *
 * `quickstart.ts` shows one agent keeping its own memory. This is the other half, and the reason
 * the network exists: an owner agent stores knowledge, a second agent registers separately, and the
 * owner grants it scoped `read` + `quote` on that one space. Nothing is shared until the grant
 * exists, the grant names the grantee's agent id, and it can be revoked in one call.
 *
 *   npm install
 *   npm run build
 *   node dist/examples/share_quickstart.js
 *
 * Against a self-hosted or local node:
 *
 *   PRIOSTACK_ENDPOINT=http://127.0.0.1:8091/rpc node dist/examples/share_quickstart.js
 */

import { pathToFileURL } from "node:url";

import { ACNClient, NotFoundError } from "../src/index.js";

const ENDPOINT = process.env["PRIOSTACK_ENDPOINT"];

interface Onboarded {
  acn: ACNClient;
  agentId: string;
}

/** Register one agent and open its session. */
async function onboard(displayName: string): Promise<Onboarded> {
  const acn = new ACNClient(ENDPOINT ? { endpoint: ENDPOINT } : {});
  const reg = await acn.register(displayName);
  await acn.connect();
  console.log(`  ${displayName}: agent ${reg.agentId}`);
  return { acn, agentId: reg.agentId };
}

/** Read a space, reporting whether it is reachable at all. */
async function canRead(acn: ACNClient, spaceId: string): Promise<boolean> {
  try {
    await acn.fetch(spaceId);
    return true;
  } catch (err) {
    if (err instanceof NotFoundError) return false;
    throw err;
  }
}

async function main(): Promise<void> {
  console.log("1. onboarding two agents");
  const owner = await onboard("typescript-owner");
  const worker = await onboard("typescript-worker");

  try {
    // defaultRights is the ceiling of what this space may ever offer. It grants nothing by itself.
    const space = await owner.acn.createSpace("shift-handover", {
      defaultRights: ["read", "quote"],
    });
    console.log(`2. owner created space ${space.spaceId}`);

    const stored = await owner.acn.store(space.spaceId, [
      { content: "Night shift found a stuck consumer on queue orders-v2.", type: "observation" },
      { content: "Restarting the consumer requires a change ticket after 22:00.", type: "declaration" },
    ]);
    console.log(`3. owner stored ${stored.count} object(s)`);

    // Before the grant the space is not merely empty to the worker — it is not there at all.
    console.log(
      (await canRead(worker.acn, space.spaceId))
        ? "4. worker could read the space BEFORE a grant — that would be a bug"
        : "4. worker cannot see the space yet (as expected)",
    );

    // The subject of a grant is the grantee's AGENT ID, not its display name or its account.
    const grant = await owner.acn.grantAccess(space.spaceId, worker.agentId, {
      rights: ["read", "quote"],
    });
    console.log(`5. granted ${grant.effectiveRights.join(", ")} (${grant.capabilityRef})`);

    // The grantee reconnects so its session picks up the widened scope.
    await worker.acn.connect();
    const hits = await worker.acn.fetch(space.spaceId, { query: "consumer" });
    console.log(`6. worker reads ${hits.matched} of ${hits.total} object(s):`);
    for (const line of hits.contents) {
      console.log(`     - ${line}`);
    }

    // Revoking is immediate and forward-only: the worker keeps nothing it has already read, and
    // loses the space on its next session.
    await owner.acn.revokeAccess(grant.capabilityRef);
    await worker.acn.connect();
    console.log(
      (await canRead(worker.acn, space.spaceId))
        ? "7. worker still reads the space after revoke — that would be a bug"
        : "7. grant revoked — the worker cannot read the space any more",
    );
  } finally {
    await worker.acn.close();
    await owner.acn.close();
  }
}

const entry = process.argv[1];
if (entry && import.meta.url === pathToFileURL(entry).href) {
  main().catch((err) => {
    console.error(err);
    process.exitCode = 1;
  });
}

export { main };
