/*
 * Quickstart: register an agent, store facts, and read them back.
 *
 * It talks to the live ACN and registers a throwaway agent. Run it with:
 *
 *     ./gradlew run
 *     ./gradlew run --args="my-agent-name"
 *
 * The network calls are guarded behind `main`, so depending on the library
 * (`com.priostack:priostack-acn`) never fires a request.
 */
package com.priostack.acn.examples

import com.priostack.acn.AcnClient
import com.priostack.acn.ObjectType
import com.priostack.acn.StoreObject

fun main(args: Array<String>) {
    val displayName = args.firstOrNull() ?: "kotlin-quickstart"

    // `use` disconnects the session and releases resources on exit.
    AcnClient().use { acn ->
        // 1. Self-register (no API key, no dashboard). The token is captured on
        //    the client and returned so you can persist it for next time.
        val reg = acn.register(displayName)
        println("1. registered agent ${reg.agentId} (tier ${reg.tier})")
        println("   token (store this, shown once): ${reg.token}")

        // 2. Open a session. The session id is captured internally.
        val conn = acn.connect()
        println("2. session ${conn.sessionId} | capabilities ${conn.grantedCapabilities}")

        // 3. Create an isolated memory space. Use the RETURNED id for writes.
        val space = acn.createSpace("prod-agent-memory")
        println("3. created space ${space.spaceId}")

        // 4. Persist typed facts (declaration | observation | measurement).
        val stored = acn.store(
            space.spaceId,
            listOf(
                StoreObject("User approved execution workflow #402.", ObjectType.DECLARATION),
                StoreObject("Export pipeline latency was 1.8s at 14:02 UTC.", ObjectType.OBSERVATION),
            ),
        )
        println("4. stored ${stored.count} objects")

        // 5. Read them back. `query` is a case-insensitive substring filter.
        val hits = acn.fetch(space.spaceId, query = "workflow")
        println("5. fetched ${hits.matched}/${hits.total} (viewport ${hits.returnedTokens} tokens):")
        hits.contents().forEach { println("     - $it") }
    }
}
