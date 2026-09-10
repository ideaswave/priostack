/*
 * Official Kotlin client for the Priostack Agent Context Network (ACN).
 *
 * The ACN is a Model Context Protocol (MCP) server reached over JSON-RPC 2.0.
 * An agent self-registers, opens a session with the returned bearer token,
 * creates isolated context spaces, stores typed facts, reads them back, and
 * shares them with other agents through scoped capability grants.
 *
 * This client speaks the exact wire contract of the live server: it unwraps the
 * MCP `result.content[0].text` envelope, raises typed exceptions on tool-level
 * denials, reuses one pooled HTTPS client, and captures the session id
 * automatically on [connect].
 */
package com.priostack.acn

import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.add
import kotlinx.serialization.json.addJsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonObject
import java.io.IOException
import java.net.URI
import java.net.http.HttpClient
import java.net.http.HttpRequest
import java.net.http.HttpResponse
import java.nio.charset.StandardCharsets
import java.time.Duration
import java.util.concurrent.atomic.AtomicInteger

/**
 * A sturdy JSON-RPC client for the Priostack ACN.
 *
 * The client owns a reusable [HttpClient] and an incrementing JSON-RPC id, and
 * is safe to share across threads. Use it with `use { }` so the session is
 * disconnected on close:
 *
 * ```
 * AcnClient().use { acn ->
 *     acn.register("my-agent")   // token captured internally
 *     acn.connect()              // session id captured internally
 *     val space = acn.createSpace("prod-memory")
 *     acn.store(space.spaceId, listOf(
 *         StoreObject("Refunds over 500 need manager approval.", ObjectType.DECLARATION),
 *     ))
 *     acn.fetch(space.spaceId, query = "refund").contents().forEach(::println)
 * }
 * ```
 *
 * @param endpoint base RPC URL; defaults to the canonical Streamable-HTTP MCP
 *   endpoint. The legacy `.../acn/rpc` path is an accepted alias.
 * @param token a previously issued bearer token, to reconnect an existing agent
 *   without registering again; [register] also sets it.
 * @param timeout per-request timeout applied to every call.
 * @param httpClient inject a pre-built [HttpClient] (custom TLS, proxy, ...);
 *   when omitted, one is built and reused.
 */
class AcnClient(
    val endpoint: String = DEFAULT_ENDPOINT,
    token: String? = null,
    private val timeout: Duration = Duration.ofSeconds(30),
    httpClient: HttpClient? = null,
) : AutoCloseable {

    /** The current bearer token, captured by [register]/[connect]. */
    var token: String? = token
        private set

    /** The current session id, captured by [connect]. */
    var sessionId: String? = null
        private set

    /** Whether a session id has been captured. */
    val connected: Boolean get() = sessionId != null

    private val http: HttpClient = httpClient ?: HttpClient.newBuilder()
        .connectTimeout(timeout)
        .build()

    private val ids = AtomicInteger(0)

    // ----------------------------------------------------------------- //
    // Transport
    // ----------------------------------------------------------------- //

    /**
     * Invoke any `noetic.*` tool and return its unwrapped `data` object.
     *
     * This is the low-level escape hatch behind every typed method — use it to
     * reach tools this client does not wrap explicitly. It performs the full
     * round trip: builds the JSON-RPC `tools/call` envelope, unwraps
     * `result.content[0].text`, and raises an [AcnToolError] (or subclass) when
     * the tool returns `ok: false`, or an [AcnTransportError] on a network,
     * HTTP, decoding, or JSON-RPC protocol failure.
     */
    fun call(method: String, arguments: JsonObject): JsonObject {
        val payload = buildJsonObject {
            put("jsonrpc", "2.0")
            put("id", ids.incrementAndGet())
            put("method", "tools/call")
            putJsonObject("params") {
                put("name", method)
                put("arguments", arguments)
            }
        }

        val request = HttpRequest.newBuilder()
            .uri(URI.create(endpoint))
            .timeout(timeout)
            .header("Content-Type", "application/json")
            // Ask for a plain JSON reply; the Streamable-HTTP endpoint would
            // otherwise be free to answer a POST as a one-shot SSE frame.
            .header("Accept", "application/json")
            .header("User-Agent", USER_AGENT)
            .POST(HttpRequest.BodyPublishers.ofString(payload.toString(), StandardCharsets.UTF_8))
            .build()

        val response: HttpResponse<String> = try {
            http.send(request, HttpResponse.BodyHandlers.ofString(StandardCharsets.UTF_8))
        } catch (e: IOException) {
            throw AcnTransportError("network error calling $method: ${e.message}", method = method, cause = e)
        } catch (e: InterruptedException) {
            Thread.currentThread().interrupt()
            throw AcnTransportError("interrupted calling $method: ${e.message}", method = method, cause = e)
        }

        val status = response.statusCode()
        val bodyText = response.body() ?: ""
        if (status >= 400) {
            throw AcnTransportError(
                "HTTP $status calling $method: ${bodyText.truncate(500)}",
                method = method,
                httpStatus = status,
            )
        }

        val root = try {
            JSON.parseToJsonElement(bodyText)
        } catch (e: SerializationException) {
            throw AcnTransportError("non-JSON response calling $method: ${bodyText.truncate(500)}", method = method, cause = e)
        }
        val rootObj = root as? JsonObject
            ?: throw AcnTransportError("malformed response calling $method: ${bodyText.truncate(500)}", method = method)

        // JSON-RPC protocol error (unknown method, bad params) — no result.
        val errorEl = rootObj["error"]
        if (errorEl != null && errorEl !is JsonNull) {
            val errObj = errorEl as? JsonObject
            val message = errObj?.stringOr("message") ?: errorEl.toString()
            val code = (errObj?.get("code") as? JsonPrimitive)?.intOrNull
            throw AcnTransportError("JSON-RPC error calling $method: $message", method = method, code = code)
        }

        val result = rootObj["result"] as? JsonObject
            ?: throw AcnTransportError("malformed response calling $method: ${bodyText.truncate(500)}", method = method)

        val envelope = unwrap(result, method)

        if (envelope["ok"].let { (it as? JsonPrimitive)?.booleanOrNull } != true) {
            throw toolErrorFor(
                envelope.stringOr("outcome"),
                envelope.stringOr("detail"),
                method = method,
                data = envelope["data"],
            )
        }

        // `data` is optional (some tools return ok with no payload).
        val data = envelope["data"]
        return data as? JsonObject ?: buildJsonObject { put("data", data ?: JsonNull) }
    }

    /** Parse the MCP `content[0].text` JSON envelope out of a result. */
    private fun unwrap(result: JsonObject, method: String): JsonObject {
        val content = result["content"] as? JsonArray
        if (content.isNullOrEmpty()) {
            throw AcnTransportError("response for $method had no content block", method = method)
        }
        val first = content[0] as? JsonObject
        val textPrim = first?.get("text") as? JsonPrimitive
        val text = if (textPrim != null && textPrim.isString) {
            textPrim.content
        } else {
            throw AcnTransportError("response for $method had no text payload", method = method)
        }
        val envelope = try {
            JSON.parseToJsonElement(text) as? JsonObject
        } catch (e: SerializationException) {
            throw AcnTransportError("could not decode envelope for $method: ${text.truncate(300)}", method = method, cause = e)
        }
        return envelope ?: throw AcnTransportError("envelope for $method was not an object", method = method)
    }

    private fun requireSession(): String =
        sessionId ?: throw AcnTransportError("no active session: call connect() first")

    // ----------------------------------------------------------------- //
    // Identity
    // ----------------------------------------------------------------- //

    /**
     * Self-register a new agent and capture its bearer token.
     *
     * Only available on the online multi-agent ACN. The token is shown once; it
     * is stored on this client ([token]) and returned so you can persist it for
     * future sessions. Raises [NotSupportedError] on a single-tenant ACN.
     */
    fun register(displayName: String = "agent"): RegisterResult {
        val data = call("noetic.register", buildJsonObject { put("displayName", displayName) })
        val tok = data.stringOr("token")
        if (tok.isEmpty()) throw AcnTransportError("register returned no token: $data", method = "noetic.register")
        token = tok
        return RegisterResult(
            token = tok,
            agentId = data.stringOr("agentId"),
            accountId = data.stringOr("accountId"),
            tier = data.stringOr("tier"),
            raw = data,
        )
    }

    /**
     * Open a session with a bearer token and capture the session id.
     *
     * Pass [token] explicitly, or rely on the token captured by [register] /
     * passed to the constructor. Re-call `connect` after being granted access
     * to a space so the widened scope is applied.
     */
    fun connect(token: String? = null, maxResponseTokens: Int = 4096): ConnectResult {
        val tok = token ?: this.token
            ?: throw AcnTransportError("connect() needs a token: register() first or pass token=...")
        val data = call("noetic.connect", buildJsonObject {
            put("token", tok)
            put("maxResponseTokens", maxResponseTokens)
        })
        // The server serialises ConnectResult with Go field names (PascalCase).
        val sid = data.stringOr("SessionID")
        if (sid.isEmpty()) throw AcnTransportError("connect returned no SessionID: $data", method = "noetic.connect")
        sessionId = sid
        this.token = tok
        return ConnectResult(
            sessionId = sid,
            resolvedAccount = data.stringOr("ResolvedAccount"),
            grantedCapabilities = data.stringList("GrantedCapabilities"),
            grantedContextRights = data.stringList("GrantedContextRights"),
            boundSpace = data.stringOr("BoundSpace"),
            resolvedMaxTokens = data.intOr("ResolvedMaxTokens"),
            raw = data,
        )
    }

    /** End the current session. Durable facts are not revoked. */
    fun disconnect(): JsonObject {
        val sid = requireSession()
        val data = call("noetic.disconnect", buildJsonObject { put("sessionId", sid) })
        sessionId = null
        return data
    }

    /**
     * Mint a fresh bearer token for this agent and retire the old one. Existing
     * sessions keep working; use the new token for future [connect] calls. The
     * new token is stored on this client and returned.
     */
    fun rotateToken(): String {
        val sid = requireSession()
        val data = call("noetic.rotate_token", buildJsonObject { put("sessionId", sid) })
        val tok = data.stringOr("token")
        if (tok.isEmpty()) throw AcnTransportError("rotate_token returned no token: $data", method = "noetic.rotate_token")
        token = tok
        return tok
    }

    /** Discover the grantable rights + world-mutation vocabulary in scope. */
    fun capabilities(): JsonObject {
        val sid = requireSession()
        return call("noetic.capabilities", buildJsonObject { put("sessionId", sid) })
    }

    // ----------------------------------------------------------------- //
    // Spaces + facts
    // ----------------------------------------------------------------- //

    /**
     * Create an isolated context space and return its resolved id.
     *
     * [defaultRights] is the ceiling of rights the space may offer to others; it
     * does not grant anything by itself.
     */
    fun createSpace(
        displayName: String,
        defaultRights: List<String>? = null,
        visibility: String? = null,
        persistenceMode: String? = null,
        protectionLevel: String? = null,
    ): SpaceResult {
        val sid = requireSession()
        val args = buildJsonObject {
            put("sessionId", sid)
            put("displayName", displayName)
            defaultRights?.let { putStrings("defaultRights", it) }
            visibility?.let { put("visibility", it) }
            persistenceMode?.let { put("persistenceMode", it) }
            protectionLevel?.let { put("protectionLevel", it) }
        }
        val data = call("noetic.create_space", args)
        val spaceId = data.stringOr("spaceId")
        if (spaceId.isEmpty()) throw AcnTransportError("create_space returned no spaceId: $data", method = "noetic.create_space")
        return SpaceResult(
            spaceId = spaceId,
            accountId = data.stringOr("accountId"),
            persistenceMode = data.stringOr("persistenceMode"),
            protectionLevel = data.stringOr("protectionLevel"),
            raw = data,
        )
    }

    /**
     * Persist typed facts into a space.
     *
     * Writing needs the write right and the `mutate` capability; the space owner
     * has both. Use the id returned by [createSpace] — the argument is named
     * `space` on the wire.
     */
    fun store(spaceId: String, objects: List<StoreObject>): StoreResult {
        val sid = requireSession()
        val encoded = buildJsonArray {
            objects.forEach { obj ->
                addJsonObject {
                    put("content", obj.content)
                    put("type", obj.type.wire)
                    if (obj.provenance.isNotEmpty()) putStrings("provenance", obj.provenance)
                }
            }
        }
        val data = call("noetic.store", buildJsonObject {
            put("sessionId", sid)
            put("space", spaceId)
            put("objects", encoded)
        })
        return StoreResult(objectRefs = data.objectList("objectRefs"), raw = data)
    }

    /**
     * Read stored objects back from a space (this is the content reader).
     *
     * [query] is a case-insensitive substring filter over content (not semantic
     * search); [limit] caps the count (0 = server default). The argument is
     * named `space` on the wire.
     */
    fun fetch(spaceId: String, query: String = "", limit: Int = 0): FetchResult {
        val sid = requireSession()
        val args = buildJsonObject {
            put("sessionId", sid)
            put("space", spaceId)
            if (query.isNotEmpty()) put("query", query)
            if (limit != 0) put("limit", limit)
        }
        val data = call("noetic.fetch", args)
        return FetchResult(
            space = data.stringOr("space", spaceId),
            objects = data.objectList("objects"),
            matched = data.intOr("matched"),
            total = data.intOr("total"),
            returnedTokens = data.intOr("returnedTokens"),
            raw = data,
        )
    }

    // ----------------------------------------------------------------- //
    // Sharing
    // ----------------------------------------------------------------- //

    /**
     * Grant another agent scoped access to a space you own.
     *
     * [rights] are content rights (`read`/`write`/`quote`/`share`/`export`/...).
     * [worldMutation] is the separate mutation ladder (`read`/`propose`/
     * `mutate`); leave it `null` and the server derives it from the rights
     * (granting `write` confers `mutate`). [subjectPrincipal] is the grantee's
     * agent id.
     */
    fun grantAccess(
        spaceId: String,
        subjectPrincipal: String,
        rights: List<String> = listOf("read", "quote"),
        worldMutation: String? = null,
        persistenceMode: String? = null,
    ): GrantResult {
        val sid = requireSession()
        val args = buildJsonObject {
            put("sessionId", sid)
            put("subjectPrincipal", subjectPrincipal)
            // The server names the space argument `resource`; `space` is sent as
            // a harmless alias for older builds (unknown fields are ignored).
            put("resource", spaceId)
            put("space", spaceId)
            putStrings("rights", rights)
            worldMutation?.let { put("worldMutation", it) }
            persistenceMode?.let { put("persistenceMode", it) }
        }
        return grantResult(call("noetic.grant", args))
    }

    /** Revoke a previously granted capability (immediate, forward-only). */
    fun revokeAccess(capabilityRef: String): JsonObject {
        val sid = requireSession()
        return call("noetic.revoke", buildJsonObject {
            put("sessionId", sid)
            put("capabilityRef", capabilityRef)
        })
    }

    /** Ask the owner of a remote space for scoped access (consumer side). */
    fun requestAccess(
        spaceId: String,
        rights: List<String>,
        persistenceMode: String? = null,
        reason: String = "",
    ): JsonObject {
        val sid = requireSession()
        val args = buildJsonObject {
            put("sessionId", sid)
            put("space", spaceId)
            // The server names this argument `rights` (not `requestedRights`).
            putStrings("rights", rights)
            persistenceMode?.let { put("persistenceMode", it) }
            if (reason.isNotEmpty()) put("reason", reason)
        }
        return call("noetic.request_access", args)
    }

    /** List pending access requests on spaces you own (owner side). */
    fun listRequests(): List<JsonObject> {
        val sid = requireSession()
        return call("noetic.list_requests", buildJsonObject { put("sessionId", sid) }).objectList("requests")
    }

    /** Approve a pending access request, minting the grant (owner side). */
    fun approveRequest(
        requestId: String,
        rights: List<String>? = null,
        worldMutation: String? = null,
        persistenceMode: String? = null,
    ): GrantResult {
        val sid = requireSession()
        val args = buildJsonObject {
            put("sessionId", sid)
            put("requestId", requestId)
            rights?.let { putStrings("rights", it) }
            worldMutation?.let { put("worldMutation", it) }
            persistenceMode?.let { put("persistenceMode", it) }
        }
        return grantResult(call("noetic.approve_request", args))
    }

    /** Deny a pending access request (owner side). */
    fun denyRequest(requestId: String): JsonObject {
        val sid = requireSession()
        return call("noetic.deny_request", buildJsonObject {
            put("sessionId", sid)
            put("requestId", requestId)
        })
    }

    // ----------------------------------------------------------------- //
    // Discovery + introspection
    // ----------------------------------------------------------------- //

    /** List publicly discoverable spaces (no session required). */
    fun discover(query: String = "", limit: Int = 0): List<JsonObject> {
        val args = buildJsonObject {
            if (query.isNotEmpty()) put("query", query)
            if (limit != 0) put("limit", limit)
        }
        return call("noetic.discover", args).objectList("spaces")
    }

    /** Set a space's discovery visibility. */
    fun publish(spaceId: String, visibility: String = "public"): JsonObject {
        val sid = requireSession()
        return call("noetic.publish", buildJsonObject {
            put("sessionId", sid)
            put("space", spaceId)
            put("visibility", visibility)
        })
    }

    /** Return scope/account/space usage metrics for the session. */
    fun metrics(): JsonObject {
        val sid = requireSession()
        return call("noetic.metrics", buildJsonObject { put("sessionId", sid) })
    }

    // ----------------------------------------------------------------- //
    // Lifecycle
    // ----------------------------------------------------------------- //

    /**
     * Best-effort disconnect of the active session, if any. Closing never
     * throws. The [HttpClient] is left untouched — it needs no explicit close
     * and may be shared/injected.
     */
    override fun close() {
        try {
            if (sessionId != null) disconnect()
        } catch (_: Exception) {
            // Closing must never raise.
        }
    }

    private fun grantResult(data: JsonObject) = GrantResult(
        capabilityRef = data.stringOr("capabilityRef"),
        subject = data.stringOr("subject"),
        resource = data.stringOr("resource"),
        effectiveRights = data.stringList("effectiveRights"),
        raw = data,
    )

    companion object {
        /** Canonical MCP endpoint (Streamable HTTP). `/acn/rpc` is a working alias. */
        const val DEFAULT_ENDPOINT: String = "https://priostack.com/mcp"

        /** Object `type` values the `store` tool accepts. */
        val STORE_KINDS: List<String> = ObjectType.entries.map { it.wire }

        private const val USER_AGENT = "priostack-kotlin/0.1.0"
        private val JSON = Json { ignoreUnknownKeys = true }
    }
}

private fun String.truncate(max: Int): String = if (length <= max) this else take(max)
