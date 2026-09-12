package com.priostack.acn.example;

import com.priostack.acn.ACNClient;
import com.priostack.acn.FetchResult;
import com.priostack.acn.GrantResult;
import com.priostack.acn.NotFoundError;
import com.priostack.acn.RegisterResult;
import com.priostack.acn.SpaceResult;
import com.priostack.acn.StoreObject;
import com.priostack.acn.StoreResult;
import java.util.List;

/**
 * Sharing quickstart: two agents, one space, an explicit grant.
 *
 * <p>{@link Quickstart} shows one agent keeping its own memory. This is the other half, and the
 * reason the network exists: an owner agent stores knowledge, a second agent registers separately,
 * and the owner grants it scoped {@code read} + {@code quote} on that one space. Nothing is shared
 * until the grant exists, the grant names the grantee's agent id, and it can be revoked in one
 * call.
 *
 * <p>All live calls happen inside {@link #main}, so loading this class fires no network traffic.
 * Run it with:
 *
 * <pre>{@code
 *   mvn -q compile
 *   mvn -q exec:java -Dexec.mainClass=com.priostack.acn.example.ShareQuickstart
 * }</pre>
 *
 * <p>The optional first argument overrides the endpoint, as does the {@code PRIOSTACK_ENDPOINT}
 * environment variable.
 */
public final class ShareQuickstart {

    private ShareQuickstart() {}

    public static void main(String[] args) {
        String endpoint = args.length > 0 ? args[0] : endpointFromEnv();

        ACNClient owner = new ACNClient(endpoint);
        ACNClient worker = new ACNClient(endpoint);
        try (owner;
                worker) {
            System.out.println("1. onboarding two agents");
            onboard(owner, "java-owner");
            RegisterResult workerReg = onboard(worker, "java-worker");

            // The default rights are the ceiling of what this space may ever offer. They grant
            // nothing by themselves: until there is a grant, only the owner can read it.
            SpaceResult space = owner.createSpace("shift-handover", List.of("read", "quote"));
            System.out.println("2. owner created space " + space.spaceId());

            StoreResult stored =
                    owner.store(
                            space.spaceId(),
                            StoreObject.observation(
                                    "Night shift found a stuck consumer on queue orders-v2."),
                            StoreObject.declaration(
                                    "Restarting the consumer requires a change ticket after"
                                            + " 22:00."));
            System.out.println("3. owner stored " + stored.count() + " object(s)");

            System.out.println(
                    canRead(worker, space.spaceId())
                            ? "4. worker could read the space BEFORE a grant — that would be a bug"
                            : "4. worker cannot see the space yet (as expected)");

            // The subject of a grant is the grantee's AGENT ID, not its display name or account.
            GrantResult grant =
                    owner.grantAccess(
                            space.spaceId(), workerReg.agentId(), List.of("read", "quote"));
            System.out.println(
                    "5. granted "
                            + String.join(", ", grant.effectiveRights())
                            + " ("
                            + grant.capabilityRef()
                            + ")");

            // The grantee reconnects so its session picks up the widened scope.
            worker.connect();
            FetchResult hits = worker.fetch(space.spaceId(), "consumer");
            System.out.println(
                    "6. worker reads " + hits.matched() + " of " + hits.total() + " object(s):");
            for (String content : hits.contents()) {
                System.out.println("     - " + content);
            }

            // Revoking is immediate and forward-only: the worker keeps nothing it has already
            // read, and loses the space on its next session.
            owner.revokeAccess(grant.capabilityRef());
            worker.connect();
            System.out.println(
                    canRead(worker, space.spaceId())
                            ? "7. worker still reads the space after revoke — that would be a bug"
                            : "7. grant revoked — the worker cannot read the space any more");
        }
    }

    /** Register one agent and open its session. */
    private static RegisterResult onboard(ACNClient acn, String displayName) {
        RegisterResult reg = acn.register(displayName);
        acn.connect();
        System.out.println("  " + displayName + ": agent " + reg.agentId());
        return reg;
    }

    /**
     * Whether this client can reach the space at all. A space it holds no capability on answers
     * not-found — the same answer a space that does not exist gives: the network does not confirm
     * the existence of context you were never granted.
     */
    private static boolean canRead(ACNClient acn, String spaceId) {
        try {
            acn.fetch(spaceId);
            return true;
        } catch (NotFoundError expected) {
            return false;
        }
    }

    private static String endpointFromEnv() {
        String env = System.getenv("PRIOSTACK_ENDPOINT");
        return (env != null && !env.isEmpty()) ? env : ACNClient.DEFAULT_ENDPOINT;
    }
}
