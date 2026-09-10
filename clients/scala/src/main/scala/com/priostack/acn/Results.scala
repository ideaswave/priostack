package com.priostack.acn

/** Typed result objects.
  *
  * The server returns plain JSON. These lightweight case classes give ergonomic,
  * type-checked access to the common calls while still exposing the full raw
  * `data` value via `raw` for anything not surfaced as a field.
  */

/** Result of [[AcnClient.register]]. */
final case class RegisterResult(
    token: String,
    agentId: String,
    accountId: String,
    tier: String,
    raw: ujson.Value = ujson.Null
)

/** Result of [[AcnClient.connect]]. Note the server uses PascalCase Go keys. */
final case class ConnectResult(
    sessionId: String,
    resolvedAccount: String,
    grantedCapabilities: Seq[String],
    grantedContextRights: Seq[String],
    boundSpace: String,
    resolvedMaxTokens: Int,
    raw: ujson.Value = ujson.Null
)

/** Result of [[AcnClient.createSpace]]. */
final case class SpaceResult(
    spaceId: String,
    accountId: String,
    persistenceMode: String,
    protectionLevel: String,
    raw: ujson.Value = ujson.Null
)

/** Result of [[AcnClient.store]]. */
final case class StoreResult(objectRefs: Seq[ujson.Value], raw: ujson.Value = ujson.Null):
  /** How many objects were ingested. */
  def count: Int = objectRefs.size

/** Result of [[AcnClient.fetch]] — the content reader. */
final case class FetchResult(
    space: String,
    objects: Seq[ujson.Value],
    matched: Int,
    total: Int,
    returnedTokens: Int,
    raw: ujson.Value = ujson.Null
):
  /** Just the `content` strings of the returned objects. */
  def contents: Seq[String] =
    objects.map(o => o.objOpt.flatMap(_.get("content")).flatMap(_.strOpt).getOrElse(""))

/** Result of [[AcnClient.grantAccess]] / [[AcnClient.approveRequest]]. */
final case class GrantResult(
    capabilityRef: String,
    subject: String,
    resource: String,
    effectiveRights: Seq[String],
    raw: ujson.Value = ujson.Null
)

/** A typed fact to persist with [[AcnClient.store]].
  *
  * `kind` is the object `type` and must be one of [[AcnClient.StoreKinds]]
  * (`declaration` / `observation` / `measurement`); anything else is rejected
  * client-side before the request is sent.
  */
final case class StoreObject(content: String, kind: String = "declaration", provenance: Seq[String] = Seq.empty)

object StoreObject:
  /** A rule or hypothesis. */
  def declaration(content: String): StoreObject = StoreObject(content, "declaration")
  /** A measured/observed fact. */
  def observation(content: String): StoreObject = StoreObject(content, "observation")
  /** A quantitative measurement. */
  def measurement(content: String): StoreObject = StoreObject(content, "measurement")
