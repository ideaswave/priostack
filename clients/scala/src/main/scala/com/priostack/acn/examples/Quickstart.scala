package com.priostack.acn.examples

import com.priostack.acn.*

/** End-to-end quickstart: register -> connect -> createSpace -> store -> fetch.
  *
  * All live calls happen inside `main`, so importing the library never fires a
  * network request. Run it against the live endpoint with:
  *
  * {{{
  *   sbt "runMain com.priostack.acn.examples.Quickstart scala-sdk-smoke"
  * }}}
  *
  * The first CLI arg overrides the display name (default `scala-quickstart`);
  * set `PRIOSTACK_ENDPOINT` to point at a different ACN.
  */
object Quickstart:
  def main(args: Array[String]): Unit =
    val displayName = args.headOption.getOrElse("scala-quickstart")
    val endpoint    = sys.env.getOrElse("PRIOSTACK_ENDPOINT", AcnClient.DefaultEndpoint)

    val acn = AcnClient(endpoint = endpoint)
    try
      val reg = acn.register(displayName)
      println(s"registered: agent=${reg.agentId} account=${reg.accountId} tier=${reg.tier}")

      val conn = acn.connect()
      println(s"connected:  session=${conn.sessionId} account=${conn.resolvedAccount}")
      println(s"            capabilities=${conn.grantedCapabilities.mkString("[", ", ", "]")}")

      val space = acn.createSpace("scala-quickstart-space")
      println(s"created:    space=${space.spaceId}")

      val stored = acn.store(
        space.spaceId,
        Seq(
          StoreObject.declaration("Refunds over $500 need manager approval."),
          StoreObject.observation("Customer #402 triggered the export pipeline.")
        )
      )
      println(s"stored:     ${stored.count} object(s)")

      val hits = acn.fetch(space.spaceId, query = "refund")
      println(s"fetched:    matched=${hits.matched} total=${hits.total} returnedTokens=${hits.returnedTokens}")
      hits.contents.foreach(c => println(s"  - $c"))
    catch
      case e: AcnToolError =>
        Console.err.println(s"[tool error: ${e.outcome}] ${e.detail}")
        sys.exit(1)
      case e: AcnTransportError =>
        Console.err.println(s"[transport error] ${e.getMessage}")
        sys.exit(1)
    finally acn.close()
