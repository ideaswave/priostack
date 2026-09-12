package com.priostack.acn

import java.io.IOException
import java.net.{ConnectException, URI}
import java.net.http.{HttpClient, HttpConnectTimeoutException, HttpRequest, HttpResponse}
import java.nio.charset.StandardCharsets
import java.time.Duration
import java.util.concurrent.atomic.AtomicInteger
import scala.language.implicitConversions // ujson.Obj(...) builders convert String/Int/Boolean values to ujson.Value

/** A sturdy JSON-RPC 2.0 client for the Priostack Agent Context Network (ACN).
  *
  * The ACN is a Model Context Protocol (MCP) server. An agent self-registers,
  * opens a session with the returned bearer token, creates isolated context
  * spaces, stores typed facts, reads them back, and shares them with other
  * agents through scoped capability grants.
  *
  * This client speaks the exact wire contract of the live server: it unwraps the
  * MCP `result.content[0].text` envelope, raises typed [[AcnToolError]]s on
  * tool-level denials, reuses one pooled HTTPS connection, retries transient
  * connection faults with backoff, and captures the session id automatically on
  * [[connect]].
  *
  * Construct with the companion [[AcnClient.apply]] (or [[AcnClient.usingClient]]
  * to inject a pre-built [[java.net.http.HttpClient]]).
  *
  * {{{
  * val acn = AcnClient()
  * acn.register("my-agent")                 // token captured internally
  * acn.connect()                            // session id captured internally
  * val space = acn.createSpace("prod-memory")
  * acn.store(space.spaceId, Seq(StoreObject.declaration("Refunds over \$500 need approval.")))
  * val hits = acn.fetch(space.spaceId, query = "refund")
  * hits.contents.foreach(println)
  * }}}
  *
  * The client is safe to share across threads: the JSON-RPC id counter is atomic
  * and the underlying [[java.net.http.HttpClient]] is thread-safe. The mutable
  * `token`/`sessionId` fields are only written by [[register]]/[[connect]]/
  * [[disconnect]], so drive those from a single thread.
  */
final class AcnClient private (
    val endpoint: String,
    private val http: HttpClient,
    val timeout: Duration,
    private val maxRetries: Int,
    private val backoffFactor: Double,
    initialToken: Option[String]
) extends AutoCloseable:

  /** The bearer token in use. Set by [[register]] / [[rotateToken]] or the constructor. */
  @volatile var token: Option[String] = initialToken

  /** The active session id, captured by [[connect]] and cleared by [[disconnect]]. */
  @volatile var sessionId: Option[String] = None

  private val ids = new AtomicInteger(0)

  /** Whether a session id has been captured. */
  def connected: Boolean = sessionId.isDefined

  // -- lifecycle ---------------------------------------------------------- //

  /** Best-effort disconnect (if connected). Never raises. Durable facts are not
    * revoked. The injected/owned HTTP client is left to the JVM to reclaim.
    */
  override def close(): Unit =
    if sessionId.isDefined then
      try { disconnect(); () }
      catch { case _: Throwable => () }

  // -- transport ---------------------------------------------------------- //

  /** Invoke any `noetic.*` tool and return its unwrapped envelope `data`.
    *
    * This is the low-level escape hatch behind every typed method — use it to
    * reach tools this client does not wrap (there are ~40). It performs the full
    * round trip: builds the JSON-RPC `tools/call` payload, unwraps
    * `result.content[0].text`, and raises an [[AcnToolError]] (or a subclass)
    * when the tool returns `ok: false`. The returned value is the envelope's
    * `data` object; tools that answer `ok` with no payload yield
    * `{"data": null}`.
    */
  def call(method: String, arguments: ujson.Obj): ujson.Value =
    val payload = ujson.Obj(
      "jsonrpc" -> "2.0",
      "id"      -> ids.incrementAndGet(),
      "method"  -> "tools/call",
      "params"  -> ujson.Obj("name" -> method, "arguments" -> arguments)
    )
    val resp   = send(payload, method)
    val status = resp.statusCode()
    if status >= 400 then
      throw new AcnTransportError(
        s"HTTP $status calling $method: ${trunc(resp.body())}",
        Some(method),
        httpStatus = Some(status)
      )

    val body =
      try ujson.read(resp.body())
      catch
        case e: Exception =>
          throw new AcnTransportError(
            s"non-JSON response calling $method: ${trunc(resp.body())}",
            Some(method),
            cause = e
          )

    // JSON-RPC protocol error (unknown method, bad params) — no result.
    body.objOpt.flatMap(_.get("error")).filter(_ != ujson.Null).foreach { err =>
      val msg  = err.objOpt.flatMap(_.get("message")).flatMap(_.strOpt).getOrElse(ujson.write(err))
      val code = err.objOpt.flatMap(_.get("code")).flatMap(_.numOpt).map(_.toInt)
      throw new AcnTransportError(s"JSON-RPC error calling $method: $msg", Some(method), code = code)
    }

    body.objOpt.flatMap(_.get("result")) match
      case Some(result: ujson.Obj) =>
        val envelope = unwrap(result, method)
        val ok       = envelope.objOpt.flatMap(_.get("ok")).flatMap(_.boolOpt).getOrElse(false)
        if !ok then
          throw AcnToolError(
            Json.str(envelope, "outcome"),
            Json.str(envelope, "detail"),
            Some(method),
            envelope.objOpt.flatMap(_.get("data"))
          )
        envelope.objOpt.flatMap(_.get("data")) match
          case Some(d: ujson.Obj) => d
          case Some(other)        => ujson.Obj("data" -> other)
          case None               => ujson.Obj("data" -> ujson.Null)
      case _ =>
        throw new AcnTransportError(
          s"malformed response calling $method: ${trunc(ujson.write(body))}",
          Some(method)
        )

  /** POST the payload with a small retry policy. Connection-phase faults
    * (connect timeout / connection refused) are retried with exponential
    * backoff because the request never reached the server; read timeouts are
    * '''not''' retried, so a non-idempotent call such as `store` is never
    * silently duplicated. HTTP 429/503 back-pressure is honoured (with any
    * `Retry-After`).
    */
  private def send(payload: ujson.Obj, method: String): HttpResponse[String] =
    val request = HttpRequest
      .newBuilder()
      .uri(URI.create(endpoint))
      .timeout(timeout)
      .header("Content-Type", "application/json")
      .header("Accept", "application/json")
      .header("User-Agent", AcnClient.UserAgent)
      .POST(HttpRequest.BodyPublishers.ofString(ujson.write(payload), StandardCharsets.UTF_8))
      .build()

    def attempt(n: Int): HttpResponse[String] =
      val outcome: Either[Throwable, HttpResponse[String]] =
        try Right(http.send(request, HttpResponse.BodyHandlers.ofString()))
        catch
          case e: InterruptedException =>
            Thread.currentThread().interrupt()
            throw new AcnTransportError(s"interrupted calling $method", Some(method), cause = e)
          case e: HttpConnectTimeoutException => Left(e)
          case e: ConnectException            => Left(e)
          case e: IOException =>
            throw new AcnTransportError(
              s"network error calling $method: ${e.getMessage}",
              Some(method),
              cause = e
            )
      outcome match
        case Right(resp) =>
          val sc = resp.statusCode()
          if (sc == 429 || sc == 503) && n < maxRetries then
            backoff(n, resp.headers().firstValue("Retry-After"))
            attempt(n + 1)
          else resp
        case Left(e) =>
          if n < maxRetries then
            backoff(n, java.util.Optional.empty[String]())
            attempt(n + 1)
          else
            throw new AcnTransportError(
              s"network error calling $method: ${e.getMessage}",
              Some(method),
              cause = e
            )

    attempt(0)

  private def backoff(attemptNo: Int, retryAfter: java.util.Optional[String]): Unit =
    val fromHeader =
      if retryAfter.isPresent then retryAfter.get().trim.toLongOption.map(_ * 1000L) else None
    val ms = fromHeader.getOrElse((backoffFactor * math.pow(2.0, attemptNo.toDouble) * 1000.0).toLong)
    if ms > 0 then
      try Thread.sleep(ms)
      catch case _: InterruptedException => Thread.currentThread().interrupt()

  /** Parse the MCP `content[0].text` JSON envelope out of a result. */
  private def unwrap(result: ujson.Obj, method: String): ujson.Value =
    result.value.get("content").flatMap(_.arrOpt).flatMap(_.headOption) match
      case None => throw new AcnTransportError(s"response for $method had no content block", Some(method))
      case Some(block) =>
        block.objOpt.flatMap(_.get("text")).flatMap(_.strOpt) match
          case None => throw new AcnTransportError(s"response for $method had no text payload", Some(method))
          case Some(text) =>
            val env =
              try ujson.read(text)
              catch
                case e: Exception =>
                  throw new AcnTransportError(
                    s"could not decode envelope for $method: ${trunc(text)}",
                    Some(method),
                    cause = e
                  )
            env match
              case o: ujson.Obj => o
              case _            => throw new AcnTransportError(s"envelope for $method was not an object", Some(method))

  private def requireSession(): String =
    sessionId.getOrElse(throw new AcnTransportError("no active session: call connect() first"))

  private def trunc(s: String, n: Int = 500): String =
    if s.length <= n then s else s.substring(0, n)

  private def arr(xs: Seq[String]): ujson.Arr = ujson.Arr(xs.map(s => ujson.Str(s))*)

  private def reqStr(v: ujson.Value, key: String, method: String): String =
    v.objOpt.flatMap(_.get(key)).flatMap(_.strOpt) match
      case Some(s) => s
      case None =>
        throw new AcnTransportError(s"$method response missing '$key': ${trunc(ujson.write(v))}", Some(method))

  // -- identity ----------------------------------------------------------- //

  /** Self-register a new agent and capture its bearer token.
    *
    * Only available on the online multi-agent ACN. The token is shown once; it
    * is stored on this client (`token`) and returned so you can persist it for
    * future sessions. Raises [[NotSupportedError]] on a single-tenant ACN.
    */
  def register(displayName: String = "agent"): RegisterResult =
    val data = call("noetic.register", ujson.Obj("displayName" -> displayName))
    val tok  = reqStr(data, "token", "noetic.register")
    token = Some(tok)
    RegisterResult(tok, Json.str(data, "agentId"), Json.str(data, "accountId"), Json.str(data, "tier"), data)

  /** Open a session with a bearer token and capture the session id.
    *
    * Pass `token` explicitly, or rely on the token captured by [[register]] /
    * passed to the constructor. Re-call `connect` after being granted access to
    * a space so the widened scope is applied.
    *
    * The connect envelope `data` uses PascalCase Go field names; this reads
    * `SessionID` (not `sessionId`) as the session id.
    */
  def connect(token: Option[String] = None, maxResponseTokens: Int = 4096): ConnectResult =
    val tok = token
      .orElse(this.token)
      .getOrElse(throw new AcnTransportError("connect() needs a token: register() first or pass token=..."))
    val data = call("noetic.connect", ujson.Obj("token" -> tok, "maxResponseTokens" -> maxResponseTokens))
    // The server serializes ConnectResult with Go field names (PascalCase).
    val sid = Json.str(data, "SessionID")
    if sid.isEmpty then
      throw new AcnTransportError(s"connect returned no SessionID: ${trunc(ujson.write(data))}", Some("noetic.connect"))
    sessionId = Some(sid)
    this.token = Some(tok)
    ConnectResult(
      sessionId = sid,
      resolvedAccount = Json.str(data, "ResolvedAccount"),
      grantedCapabilities = Json.strSeq(data, "GrantedCapabilities"),
      grantedContextRights = Json.strSeq(data, "GrantedContextRights"),
      boundSpace = Json.str(data, "BoundSpace"),
      resolvedMaxTokens = Json.int(data, "ResolvedMaxTokens"),
      raw = data
    )

  /** End the current session. Durable facts are '''not''' revoked. */
  def disconnect(): ujson.Value =
    val sid  = requireSession()
    val data = call("noetic.disconnect", ujson.Obj("sessionId" -> sid))
    sessionId = None
    data

  /** Mint a fresh bearer token for this agent and retire the old one. Existing
    * sessions keep working; the new token is stored on this client and returned.
    */
  def rotateToken(): String =
    val sid  = requireSession()
    val data = call("noetic.rotate_token", ujson.Obj("sessionId" -> sid))
    val tok  = reqStr(data, "token", "noetic.rotate_token")
    token = Some(tok)
    tok

  /** Discover the grantable rights + world-mutation vocabulary in scope. */
  def capabilities(): ujson.Value =
    call("noetic.capabilities", ujson.Obj("sessionId" -> requireSession()))

  // -- spaces + facts ----------------------------------------------------- //

  /** Create an isolated context space and return its resolved id.
    *
    * `defaultRights` is the ceiling of rights the space may offer to others; it
    * does not grant anything by itself. Use the '''returned''' `spaceId` for
    * subsequent writes.
    */
  def createSpace(
      displayName: String,
      defaultRights: Seq[String] = Seq.empty,
      visibility: Option[String] = None,
      persistenceMode: Option[String] = None,
      protectionLevel: Option[String] = None
  ): SpaceResult =
    val args = ujson.Obj("sessionId" -> requireSession(), "displayName" -> displayName)
    if defaultRights.nonEmpty then args.value("defaultRights") = arr(defaultRights)
    visibility.foreach(v => args.value("visibility") = ujson.Str(v))
    persistenceMode.foreach(v => args.value("persistenceMode") = ujson.Str(v))
    protectionLevel.foreach(v => args.value("protectionLevel") = ujson.Str(v))
    val data = call("noetic.create_space", args)
    SpaceResult(
      spaceId = reqStr(data, "spaceId", "noetic.create_space"),
      accountId = Json.str(data, "accountId"),
      persistenceMode = Json.str(data, "persistenceMode"),
      protectionLevel = Json.str(data, "protectionLevel"),
      raw = data
    )

  /** Persist typed facts into a space (the write path).
    *
    * Writing needs the write right and the `mutate` capability; the space owner
    * has both. The arg key for the space id is `space`.
    */
  def store(spaceId: String, objects: Seq[StoreObject]): StoreResult =
    val sid  = requireSession()
    val objs = objects.map(normalizeObject)
    val data = call("noetic.store", ujson.Obj("sessionId" -> sid, "space" -> spaceId, "objects" -> ujson.Arr(objs*)))
    StoreResult(Json.objSeq(data, "objectRefs"), data)

  private def normalizeObject(o: StoreObject): ujson.Obj =
    if !AcnClient.StoreKinds.contains(o.kind) then
      throw new IllegalArgumentException(
        s"invalid object type '${o.kind}'; must be one of ${AcnClient.StoreKinds.mkString(", ")}"
      )
    val obj = ujson.Obj("content" -> o.content, "type" -> o.kind)
    if o.provenance.nonEmpty then obj.value("provenance") = arr(o.provenance)
    obj

  /** Read stored objects back from a space (the content reader).
    *
    * `query` is a case-insensitive '''substring''' filter over content (not
    * semantic search); `limit` caps the count (0 = server default). The arg key
    * for the space id is `space`.
    */
  def fetch(spaceId: String, query: String = "", limit: Int = 0): FetchResult =
    val args = ujson.Obj("sessionId" -> requireSession(), "space" -> spaceId)
    if query.nonEmpty then args.value("query") = ujson.Str(query)
    if limit > 0 then args.value("limit") = ujson.Num(limit.toDouble)
    val data = call("noetic.fetch", args)
    FetchResult(
      space = Json.str(data, "space", spaceId),
      objects = Json.objSeq(data, "objects"),
      matched = Json.int(data, "matched"),
      total = Json.int(data, "total"),
      returnedTokens = Json.int(data, "returnedTokens"),
      raw = data
    )

  // -- sharing ------------------------------------------------------------ //

  /** Grant another agent scoped access to a space you own.
    *
    * `rights` are content rights (`read`/`write`/`quote`/`share`/`export`/...).
    * `worldMutation` is the separate mutation ladder (`read`/`propose`/`mutate`);
    * leave it `None` and the server derives it from the rights (granting `write`
    * confers `mutate`). The space arg is named `resource`; `subjectPrincipal` is
    * the grantee's agentId.
    */
  def grantAccess(
      spaceId: String,
      subjectPrincipal: String,
      rights: Seq[String] = Seq("read", "quote"),
      worldMutation: Option[String] = None,
      persistenceMode: Option[String] = None
  ): GrantResult =
    // The server names the space argument `resource`. `space` is sent too as a
    // harmless alias for older builds; unknown fields are ignored server-side.
    val args = ujson.Obj(
      "sessionId"        -> requireSession(),
      "subjectPrincipal" -> subjectPrincipal,
      "resource"         -> spaceId,
      "space"            -> spaceId,
      "rights"           -> arr(rights)
    )
    worldMutation.foreach(v => args.value("worldMutation") = ujson.Str(v))
    persistenceMode.foreach(v => args.value("persistenceMode") = ujson.Str(v))
    grantResult(call("noetic.grant", args))

  /** Revoke a previously granted capability (immediate, forward-only). */
  def revokeAccess(capabilityRef: String): ujson.Value =
    call("noetic.revoke", ujson.Obj("sessionId" -> requireSession(), "capabilityRef" -> capabilityRef))

  /** Ask the owner of a remote space for scoped access (consumer side).
    *
    * The rights arg is named `rights`; the space arg is `space`.
    */
  def requestAccess(
      spaceId: String,
      rights: Seq[String],
      reason: String = "",
      persistenceMode: Option[String] = None
  ): ujson.Value =
    val args = ujson.Obj("sessionId" -> requireSession(), "space" -> spaceId, "rights" -> arr(rights))
    persistenceMode.foreach(v => args.value("persistenceMode") = ujson.Str(v))
    if reason.nonEmpty then args.value("reason") = ujson.Str(reason)
    call("noetic.request_access", args)

  /** List pending access requests on spaces you own (owner side). */
  def listRequests(): Seq[ujson.Value] =
    Json.objSeq(call("noetic.list_requests", ujson.Obj("sessionId" -> requireSession())), "requests")

  /** Approve a pending access request, minting the grant (owner side). */
  def approveRequest(
      requestId: String,
      rights: Option[Seq[String]] = None,
      worldMutation: Option[String] = None,
      persistenceMode: Option[String] = None
  ): GrantResult =
    val args = ujson.Obj("sessionId" -> requireSession(), "requestId" -> requestId)
    rights.foreach(r => args.value("rights") = arr(r))
    worldMutation.foreach(v => args.value("worldMutation") = ujson.Str(v))
    persistenceMode.foreach(v => args.value("persistenceMode") = ujson.Str(v))
    grantResult(call("noetic.approve_request", args))

  /** Deny a pending access request (owner side). */
  def denyRequest(requestId: String): ujson.Value =
    call("noetic.deny_request", ujson.Obj("sessionId" -> requireSession(), "requestId" -> requestId))

  private def grantResult(data: ujson.Value): GrantResult =
    GrantResult(
      capabilityRef = Json.str(data, "capabilityRef"),
      subject = Json.str(data, "subject"),
      resource = Json.str(data, "resource"),
      effectiveRights = Json.strSeq(data, "effectiveRights"),
      raw = data
    )

  // -- discovery + introspection ----------------------------------------- //

  /** List publicly discoverable spaces (no session required). */
  def discover(query: String = "", limit: Int = 0): Seq[ujson.Value] =
    val args = ujson.Obj()
    if query.nonEmpty then args.value("query") = ujson.Str(query)
    if limit > 0 then args.value("limit") = ujson.Num(limit.toDouble)
    Json.objSeq(call("noetic.discover", args), "spaces")

  /** Set a space's discovery visibility. */
  def publish(spaceId: String, visibility: String = "public"): ujson.Value =
    call("noetic.publish", ujson.Obj("sessionId" -> requireSession(), "space" -> spaceId, "visibility" -> visibility))

  /** Return scope/account/space usage metrics for the session. */
  def metrics(): ujson.Value =
    call("noetic.metrics", ujson.Obj("sessionId" -> requireSession()))

end AcnClient

object AcnClient:
  /** Canonical MCP endpoint (Streamable HTTP). `/acn/rpc` is a working alias. */
  val DefaultEndpoint: String = "https://priostack.com/mcp"

  /** Object `type` values the `store` tool accepts. Anything else is rejected. */
  val StoreKinds: Set[String] = Set("declaration", "observation", "measurement")

  private[acn] val UserAgent: String = "priostack-scala/0.3.0"

  /** Create a client that owns a freshly built [[java.net.http.HttpClient]]. */
  def apply(
      endpoint: String = DefaultEndpoint,
      token: Option[String] = None,
      timeout: Duration = Duration.ofSeconds(30),
      maxRetries: Int = 3,
      backoffFactor: Double = 0.5
  ): AcnClient =
    val http = HttpClient
      .newBuilder()
      .connectTimeout(timeout)
      .followRedirects(HttpClient.Redirect.NORMAL)
      .build()
    new AcnClient(endpoint, http, timeout, maxRetries, backoffFactor, token)

  /** Create a client over a caller-supplied [[java.net.http.HttpClient]] (e.g.
    * with custom proxy/TLS/executor settings).
    */
  def usingClient(
      http: HttpClient,
      endpoint: String = DefaultEndpoint,
      token: Option[String] = None,
      timeout: Duration = Duration.ofSeconds(30),
      maxRetries: Int = 3,
      backoffFactor: Double = 0.5
  ): AcnClient =
    new AcnClient(endpoint, http, timeout, maxRetries, backoffFactor, token)

/** Small null-safe readers over the dynamic `ujson` envelope. */
private object Json:
  def str(v: ujson.Value, key: String, default: String = ""): String =
    v.objOpt.flatMap(_.get(key)).flatMap(_.strOpt).getOrElse(default)

  def int(v: ujson.Value, key: String, default: Int = 0): Int =
    v.objOpt.flatMap(_.get(key)).flatMap(_.numOpt).map(_.toInt).getOrElse(default)

  def strSeq(v: ujson.Value, key: String): Seq[String] =
    v.objOpt.flatMap(_.get(key)).flatMap(_.arrOpt).map(_.iterator.flatMap(_.strOpt).toSeq).getOrElse(Seq.empty)

  def objSeq(v: ujson.Value, key: String): Seq[ujson.Value] =
    v.objOpt.flatMap(_.get(key)).flatMap(_.arrOpt).map(_.toSeq).getOrElse(Seq.empty)
