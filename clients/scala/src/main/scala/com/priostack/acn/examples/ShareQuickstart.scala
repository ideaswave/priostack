package com.priostack.acn.examples

import com.priostack.acn.*

/** Sharing quickstart: two agents, one space, an explicit grant.
  *
  * [[Quickstart]] shows one agent keeping its own memory. This is the other half, and the reason
  * the network exists: an owner agent stores knowledge, a second agent registers separately, and
  * the owner grants it scoped `read` + `quote` on that one space. Nothing is shared until the grant
  * exists, the grant names the grantee's agent id, and it can be revoked in one call.
  *
  * All live calls happen inside `main`, so importing the library never fires a network request.
  * Run it with:
  *
  * {{{
  *   sbt "runMain com.priostack.acn.examples.ShareQuickstart"
  * }}}
  *
  * Set `PRIOSTACK_ENDPOINT` to point at a self-hosted or local node.
  */
object ShareQuickstart:

  /** Register one agent and open its session. */
  private def onboard(endpoint: String, displayName: String): (AcnClient, String) =
    val acn = AcnClient(endpoint = endpoint)
    val reg = acn.register(displayName)
    acn.connect()
    println(s"  $displayName: agent ${reg.agentId}")
    (acn, reg.agentId)

  /** Whether this client can reach the space at all. A space it holds no capability on answers
    * not-found — the same answer a space that does not exist gives: the network does not confirm
    * the existence of context you were never granted.
    */
  private def canRead(acn: AcnClient, spaceId: String): Boolean =
    try
      acn.fetch(spaceId)
      true
    catch case _: NotFoundError => false

  def main(args: Array[String]): Unit =
    val endpoint = sys.env.getOrElse("PRIOSTACK_ENDPOINT", AcnClient.DefaultEndpoint)

    println("1. onboarding two agents")
    val (owner, _)            = onboard(endpoint, "scala-owner")
    val (worker, workerAgent) = onboard(endpoint, "scala-worker")

    try
      // defaultRights is the ceiling of what this space may ever offer. It grants nothing by
      // itself: until there is a grant, only the owner can read it.
      val space = owner.createSpace("shift-handover", defaultRights = Seq("read", "quote"))
      println(s"2. owner created space ${space.spaceId}")

      val stored = owner.store(
        space.spaceId,
        Seq(
          StoreObject.observation("Night shift found a stuck consumer on queue orders-v2."),
          StoreObject.declaration("Restarting the consumer requires a change ticket after 22:00.")
        )
      )
      println(s"3. owner stored ${stored.count} object(s)")

      println(
        if canRead(worker, space.spaceId) then
          "4. worker could read the space BEFORE a grant — that would be a bug"
        else "4. worker cannot see the space yet (as expected)"
      )

      // The subject of a grant is the grantee's AGENT ID, not its display name or its account.
      val grant = owner.grantAccess(space.spaceId, workerAgent, rights = Seq("read", "quote"))
      println(s"5. granted ${grant.effectiveRights.mkString(", ")} (${grant.capabilityRef})")

      // The grantee reconnects so its session picks up the widened scope.
      worker.connect()
      val hits = worker.fetch(space.spaceId, query = "consumer")
      println(s"6. worker reads ${hits.matched} of ${hits.total} object(s):")
      hits.contents.foreach(c => println(s"     - $c"))

      // Revoking is immediate and forward-only: the worker keeps nothing it has already read, and
      // loses the space on its next session.
      owner.revokeAccess(grant.capabilityRef)
      worker.connect()
      println(
        if canRead(worker, space.spaceId) then
          "7. worker still reads the space after revoke — that would be a bug"
        else "7. grant revoked — the worker cannot read the space any more"
      )
    catch
      case e: AcnToolError =>
        Console.err.println(s"[tool error: ${e.outcome}] ${e.detail}")
        sys.exit(1)
      case e: AcnTransportError =>
        Console.err.println(s"[transport error] ${e.getMessage}")
        sys.exit(1)
    finally
      worker.close()
      owner.close()
