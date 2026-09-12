/*
 * Sharing quickstart: two agents, one space, an explicit grant.
 *
 * Quickstart.kt shows one agent keeping its own memory. This is the other half, and the reason the
 * network exists: an owner agent stores knowledge, a second agent registers separately, and the
 * owner grants it scoped `read` + `quote` on that one space. Nothing is shared until the grant
 * exists, the grant names the grantee's agent id, and it can be revoked in one call.
 *
 *     ./gradlew run -PmainClass=com.priostack.acn.examples.ShareQuickstartKt
 *
 * Against a self-hosted or local node:
 *
 *     PRIOSTACK_ENDPOINT=http://127.0.0.1:8091/rpc ./gradlew run \
 *         -PmainClass=com.priostack.acn.examples.ShareQuickstartKt
 *
 * The network calls are guarded behind `main`, so depending on the library never fires a request.
 */
package com.priostack.acn.examples

import com.priostack.acn.AcnClient
import com.priostack.acn.NotFoundError
import com.priostack.acn.ObjectType
import com.priostack.acn.StoreObject

/** Register one agent and open its session. */
private fun AcnClient.onboard(displayName: String): String {
    val reg = register(displayName)
    connect()
    println("  $displayName: agent ${reg.agentId}")
    return reg.agentId
}

/**
 * Whether this client can reach the space at all. A space it holds no capability on answers
 * not-found — the same answer a space that does not exist gives: the network does not confirm the
 * existence of context you were never granted.
 */
private fun AcnClient.canRead(spaceId: String): Boolean =
    try {
        fetch(spaceId)
        true
    } catch (expected: NotFoundError) {
        false
    }

fun main(args: Array<String>) {
    val endpoint = args.firstOrNull()
        ?: System.getenv("PRIOSTACK_ENDPOINT")?.takeIf { it.isNotEmpty() }
        ?: AcnClient.DEFAULT_ENDPOINT

    // `use` disconnects each session and releases resources on exit.
    AcnClient(endpoint).use { owner ->
        AcnClient(endpoint).use { worker ->
            println("1. onboarding two agents")
            owner.onboard("kotlin-owner")
            val workerId = worker.onboard("kotlin-worker")

            // defaultRights is the ceiling of what this space may ever offer. It grants nothing by
            // itself: until there is a grant, only the owner can read it.
            val space = owner.createSpace("shift-handover", defaultRights = listOf("read", "quote"))
            println("2. owner created space ${space.spaceId}")

            val stored = owner.store(
                space.spaceId,
                listOf(
                    StoreObject(
                        "Night shift found a stuck consumer on queue orders-v2.",
                        ObjectType.OBSERVATION,
                    ),
                    StoreObject(
                        "Restarting the consumer requires a change ticket after 22:00.",
                        ObjectType.DECLARATION,
                    ),
                ),
            )
            println("3. owner stored ${stored.count} object(s)")

            println(
                if (worker.canRead(space.spaceId)) {
                    "4. worker could read the space BEFORE a grant — that would be a bug"
                } else {
                    "4. worker cannot see the space yet (as expected)"
                },
            )

            // The subject of a grant is the grantee's AGENT ID, not its display name or account.
            val grant = owner.grantAccess(space.spaceId, workerId, rights = listOf("read", "quote"))
            println("5. granted ${grant.effectiveRights.joinToString(", ")} (${grant.capabilityRef})")

            // The grantee reconnects so its session picks up the widened scope.
            worker.connect()
            val hits = worker.fetch(space.spaceId, query = "consumer")
            println("6. worker reads ${hits.matched} of ${hits.total} object(s):")
            hits.contents().forEach { println("     - $it") }

            // Revoking is immediate and forward-only: the worker keeps nothing it has already
            // read, and loses the space on its next session.
            owner.revokeAccess(grant.capabilityRef)
            worker.connect()
            println(
                if (worker.canRead(space.spaceId)) {
                    "7. worker still reads the space after revoke — that would be a bug"
                } else {
                    "7. grant revoked — the worker cannot read the space any more"
                },
            )
        }
    }
}
