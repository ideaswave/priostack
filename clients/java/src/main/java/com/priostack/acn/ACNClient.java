package com.priostack.acn;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import java.io.IOException;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicLong;

/**
 * Official Java client for the Priostack Agent Context Network (ACN).
 *
 * <p>The ACN is a Model Context Protocol (MCP) server reached over JSON-RPC
 * 2.0. An agent self-registers, opens a session with the returned bearer
 * token, creates isolated context spaces, stores typed facts, reads them back,
 * and shares them with other agents through scoped capability grants.
 *
 * <p>This client speaks the exact wire contract of the live server: it unwraps
 * the MCP {@code result.content[0].text} envelope, raises a typed
 * {@link ACNToolError} on tool-level denials, reuses one pooled
 * {@link HttpClient}, and captures the session id automatically on
 * {@link #connect}.
 *
 * <h2>Quickstart</h2>
 * <pre>{@code
 * try (ACNClient acn = new ACNClient()) {
 *     acn.register("my-agent");                 // token captured internally
 *     acn.connect();                            // session id captured internally
 *     SpaceResult space = acn.createSpace("prod-memory");
 *     acn.store(space.spaceId(), List.of(
 *         StoreObject.declaration("Refunds over $500 need manager approval.")));
 *     FetchResult hits = acn.fetch(space.spaceId(), "refund");
 *     hits.contents().forEach(System.out::println);
 * }
 * }</pre>
 *
 * <p>The client is safe to share across threads: the JSON-RPC id counter is
 * atomic and the {@link ObjectMapper} is used only for stateless read/write.
 */
public final class ACNClient implements AutoCloseable {

    /** Canonical MCP endpoint (Streamable HTTP). {@code /acn/rpc} is a working alias. */
    public static final String DEFAULT_ENDPOINT = "https://priostack.com/mcp";

    private static final String USER_AGENT = "priostack-java/0.3.0";
    private static final Duration DEFAULT_TIMEOUT = Duration.ofSeconds(30);
    private static final List<String> DEFAULT_GRANT_RIGHTS = List.of("read", "quote");

    private final URI endpoint;
    private final HttpClient http;
    private final ObjectMapper mapper = new ObjectMapper();
    private final Duration timeout;
    private final AtomicLong ids = new AtomicLong(0);

    private volatile String token;
    private volatile String sessionId;

    /** Build a client against the canonical endpoint with a 30s timeout. */
    public ACNClient() {
        this(DEFAULT_ENDPOINT, null, DEFAULT_TIMEOUT);
    }

    /** Build a client against a custom endpoint. */
    public ACNClient(String endpoint) {
        this(endpoint, null, DEFAULT_TIMEOUT);
    }

    /** Build a client with a pre-issued bearer token (reconnect an existing agent). */
    public ACNClient(String endpoint, String token) {
        this(endpoint, token, DEFAULT_TIMEOUT);
    }

    /**
     * Full constructor.
     *
     * @param endpoint base RPC URL; {@code null} falls back to {@link #DEFAULT_ENDPOINT}
     * @param token a previously issued bearer token, or {@code null}
     * @param timeout per-request timeout (connect + read); {@code null} falls back to 30s
     */
    public ACNClient(String endpoint, String token, Duration timeout) {
        this.endpoint = URI.create(endpoint == null ? DEFAULT_ENDPOINT : endpoint);
        this.token = token;
        this.timeout = timeout == null ? DEFAULT_TIMEOUT : timeout;
        this.http = HttpClient.newBuilder().connectTimeout(this.timeout).build();
    }

    // -- lifecycle --------------------------------------------------------- //

    /** Best-effort disconnect (if connected) and release the HTTP pool. */
    @Override
    public void close() {
        try {
            if (sessionId != null) {
                disconnect();
            }
        } catch (RuntimeException ignored) {
            // closing must never raise
        } finally {
            http.close();
        }
    }

    /** Whether a session id has been captured. */
    public boolean connected() {
        return sessionId != null;
    }

    /** The bearer token captured by {@link #register}/{@link #connect}, or {@code null}. */
    public String token() {
        return token;
    }

    /** The current session id, or {@code null} if not connected. */
    public String sessionId() {
        return sessionId;
    }

    // -- transport / escape hatch ------------------------------------------ //

    /**
     * Invoke any {@code noetic.*} tool and return its unwrapped {@code data}
     * object.
     *
     * <p>This is the low-level escape hatch behind every typed method — use it
     * to reach tools this client does not wrap explicitly (there are ~40). It
     * performs the full round trip: builds the JSON-RPC {@code tools/call}
     * envelope, unwraps {@code result.content[0].text}, and raises a typed
     * {@link ACNToolError} when the tool returns {@code ok: false} or an
     * {@link ACNTransportError} on any transport/protocol failure.
     *
     * @return the envelope {@code data} object; an empty object when the tool
     *     returned {@code ok} with no payload, or {@code {"data": <value>}}
     *     when {@code data} was a non-object value.
     */
    public JsonNode call(String method, Map<String, Object> arguments) {
        ObjectNode payload = mapper.createObjectNode();
        payload.put("jsonrpc", "2.0");
        payload.put("id", ids.incrementAndGet());
        payload.put("method", "tools/call");
        ObjectNode params = payload.putObject("params");
        params.put("name", method);
        params.set("arguments", mapper.valueToTree(arguments == null ? Map.of() : arguments));

        String requestBody;
        try {
            requestBody = mapper.writeValueAsString(payload);
        } catch (JsonProcessingException e) {
            throw new ACNTransportError(
                    "could not encode request for " + method + ": " + e.getMessage(),
                    method, null, null, e);
        }

        HttpRequest req =
                HttpRequest.newBuilder(endpoint)
                        .timeout(timeout)
                        .header("Content-Type", "application/json")
                        // Ask for a plain JSON reply; the Streamable-HTTP endpoint would
                        // otherwise be free to answer a POST as a one-shot SSE frame.
                        .header("Accept", "application/json")
                        .header("User-Agent", USER_AGENT)
                        .POST(HttpRequest.BodyPublishers.ofString(requestBody, StandardCharsets.UTF_8))
                        .build();

        HttpResponse<String> resp;
        try {
            resp = http.send(req, HttpResponse.BodyHandlers.ofString(StandardCharsets.UTF_8));
        } catch (IOException e) {
            throw new ACNTransportError(
                    "network error calling " + method + ": " + e.getMessage(), method, null, null, e);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new ACNTransportError("interrupted calling " + method, method, null, null, e);
        }

        int status = resp.statusCode();
        if (status >= 400) {
            throw new ACNTransportError(
                    "HTTP " + status + " calling " + method + ": " + truncate(resp.body(), 500),
                    method, null, status);
        }

        JsonNode body;
        try {
            body = mapper.readTree(resp.body());
        } catch (JsonProcessingException e) {
            throw new ACNTransportError(
                    "non-JSON response calling " + method + ": " + truncate(resp.body(), 500),
                    method, null, null, e);
        }
        if (body == null || body.isMissingNode() || body.isNull()) {
            throw new ACNTransportError("empty response calling " + method, method);
        }

        // JSON-RPC protocol error (unknown method, bad params) — no result.
        JsonNode err = body.get("error");
        if (err != null && !err.isNull()) {
            Integer code = err.path("code").isNumber() ? err.get("code").asInt() : null;
            String msg = err.path("message").asText(err.toString());
            throw new ACNTransportError(
                    "JSON-RPC error calling " + method + ": " + msg, method, code, null);
        }

        JsonNode result = body.get("result");
        if (result == null || !result.isObject()) {
            throw new ACNTransportError(
                    "malformed response calling " + method + ": " + truncate(body.toString(), 500),
                    method);
        }

        JsonNode envelope = unwrap(result, method);
        if (!envelope.path("ok").asBoolean(false)) {
            throw ACNToolError.forOutcome(
                    envelope.path("outcome").asText(""),
                    envelope.path("detail").asText(""),
                    method,
                    envelope.get("data"));
        }

        // `data` is optional (some tools return ok with no payload).
        JsonNode data = envelope.get("data");
        if (data == null || data.isNull() || data.isMissingNode()) {
            return mapper.createObjectNode();
        }
        if (!data.isObject()) {
            ObjectNode wrap = mapper.createObjectNode();
            wrap.set("data", data);
            return wrap;
        }
        return data;
    }

    /** Parse the MCP {@code content[0].text} JSON envelope out of a result. */
    private JsonNode unwrap(JsonNode result, String method) {
        JsonNode content = result.get("content");
        if (content == null || !content.isArray() || content.isEmpty()) {
            throw new ACNTransportError("response for " + method + " had no content block", method);
        }
        JsonNode first = content.get(0);
        JsonNode textNode = first == null ? null : first.get("text");
        if (textNode == null || !textNode.isTextual()) {
            throw new ACNTransportError("response for " + method + " had no text payload", method);
        }
        JsonNode envelope;
        try {
            envelope = mapper.readTree(textNode.asText());
        } catch (JsonProcessingException e) {
            throw new ACNTransportError(
                    "could not decode envelope for " + method + ": " + truncate(textNode.asText(), 300),
                    method, null, null, e);
        }
        if (envelope == null || !envelope.isObject()) {
            throw new ACNTransportError("envelope for " + method + " was not an object", method);
        }
        return envelope;
    }

    private String requireSession() {
        String sid = sessionId;
        if (sid == null || sid.isEmpty()) {
            throw new ACNTransportError("no active session: call connect() first", null);
        }
        return sid;
    }

    // -- identity ---------------------------------------------------------- //

    /** Self-register a new agent named {@code "agent"} and capture its token. */
    public RegisterResult register() {
        return register("agent");
    }

    /**
     * Self-register a new agent and capture its bearer token.
     *
     * <p>Only available on the online multi-agent ACN. The token is shown once;
     * it is stored on this client ({@link #token()}) and returned so you can
     * persist it for future sessions. Throws {@link NotSupportedError} on a
     * single-tenant ACN that does not offer self-registration.
     */
    public RegisterResult register(String displayName) {
        JsonNode data =
                call("noetic.register", Map.of("displayName", displayName == null ? "agent" : displayName));
        this.token = requireText(data, "token", "noetic.register");
        return new RegisterResult(
                this.token,
                data.path("agentId").asText(""),
                data.path("accountId").asText(""),
                data.path("tier").asText(""),
                data);
    }

    /** Open a session with the captured token and a 4096-token response cap. */
    public ConnectResult connect() {
        return connect(null, 4096);
    }

    /** Open a session with an explicit token and a 4096-token response cap. */
    public ConnectResult connect(String token) {
        return connect(token, 4096);
    }

    /**
     * Open a session with a bearer token and capture the session id.
     *
     * <p>Pass {@code token} explicitly, or rely on the token captured by
     * {@link #register}/the constructor. Re-call {@code connect} after being
     * granted access to a space so the widened scope is applied.
     *
     * <p>The connect envelope's {@code data} uses PascalCase Go field names, so
     * the session id is read from {@code SessionID} (not {@code sessionId}).
     */
    public ConnectResult connect(String token, int maxResponseTokens) {
        String tok = (token != null && !token.isEmpty()) ? token : this.token;
        if (tok == null || tok.isEmpty()) {
            throw new ACNTransportError(
                    "connect() needs a token: register() first or pass a token", "noetic.connect");
        }
        JsonNode data =
                call("noetic.connect", Map.of("token", tok, "maxResponseTokens", maxResponseTokens));
        JsonNode sid = data.get("SessionID");
        if (sid == null || !sid.isTextual() || sid.asText().isEmpty()) {
            throw new ACNTransportError(
                    "connect returned no SessionID: " + truncate(data.toString(), 300), "noetic.connect");
        }
        this.sessionId = sid.asText();
        this.token = tok;
        return new ConnectResult(
                this.sessionId,
                data.path("ResolvedAccount").asText(""),
                stringList(data.get("GrantedCapabilities")),
                stringList(data.get("GrantedContextRights")),
                data.path("BoundSpace").asText(""),
                data.path("ResolvedMaxTokens").asInt(0),
                data);
    }

    /** End the current session. Durable facts are <b>not</b> revoked. */
    public JsonNode disconnect() {
        String sid = requireSession();
        JsonNode data = call("noetic.disconnect", Map.of("sessionId", sid));
        this.sessionId = null;
        return data;
    }

    /**
     * Mint a fresh bearer token for this agent and retire the old one.
     *
     * <p>Existing sessions keep working; use the new token for future
     * {@code connect} calls. The new token is stored on this client and returned.
     */
    public String rotateToken() {
        String sid = requireSession();
        JsonNode data = call("noetic.rotate_token", Map.of("sessionId", sid));
        this.token = requireText(data, "token", "noetic.rotate_token");
        return this.token;
    }

    /** Discover the grantable rights + world-mutation vocabulary in scope. */
    public JsonNode capabilities() {
        String sid = requireSession();
        return call("noetic.capabilities", Map.of("sessionId", sid));
    }

    // -- spaces + facts ---------------------------------------------------- //

    /** Create an isolated context space and return its resolved id. */
    public SpaceResult createSpace(String displayName) {
        return createSpace(displayName, null);
    }

    /**
     * Create an isolated context space and return its resolved id.
     *
     * <p>{@code defaultRights} is the ceiling of rights the space may offer to
     * others; it does not grant anything by itself.
     */
    public SpaceResult createSpace(String displayName, List<String> defaultRights) {
        String sid = requireSession();
        Map<String, Object> args = new LinkedHashMap<>();
        args.put("sessionId", sid);
        args.put("displayName", displayName);
        if (defaultRights != null && !defaultRights.isEmpty()) {
            args.put("defaultRights", new ArrayList<>(defaultRights));
        }
        JsonNode data = call("noetic.create_space", args);
        return new SpaceResult(
                requireText(data, "spaceId", "noetic.create_space"),
                data.path("accountId").asText(""),
                data.path("persistenceMode").asText(""),
                data.path("protectionLevel").asText(""),
                data);
    }

    /** Persist typed facts into a space (varargs form). */
    public StoreResult store(String spaceId, StoreObject... objects) {
        return store(spaceId, List.of(objects));
    }

    /**
     * Persist typed facts into a space.
     *
     * <p>Each object carries a {@code content} string and an {@link ObjectType}
     * ({@code declaration}/{@code observation}/{@code measurement}). Writing
     * needs the write right and the {@code mutate} capability; the space owner
     * has both. The argument key on the wire is {@code space}.
     */
    public StoreResult store(String spaceId, List<StoreObject> objects) {
        String sid = requireSession();
        if (objects == null || objects.isEmpty()) {
            throw new IllegalArgumentException("store() needs at least one object");
        }
        List<Map<String, Object>> objs = new ArrayList<>(objects.size());
        for (StoreObject o : objects) {
            if (o == null) {
                throw new IllegalArgumentException("store() objects must not be null");
            }
            objs.add(o.toWire());
        }
        Map<String, Object> args = new LinkedHashMap<>();
        args.put("sessionId", sid);
        args.put("space", spaceId);
        args.put("objects", objs);
        JsonNode data = call("noetic.store", args);
        return new StoreResult(nodeList(data.get("objectRefs")), data);
    }

    /** Read every stored object back from a space. */
    public FetchResult fetch(String spaceId) {
        return fetch(spaceId, "", 0);
    }

    /** Read stored objects whose content contains {@code query} (substring, case-insensitive). */
    public FetchResult fetch(String spaceId, String query) {
        return fetch(spaceId, query, 0);
    }

    /**
     * Read stored objects back from a space (this is the content reader).
     *
     * <p>{@code query} is a case-insensitive <b>substring</b> filter over
     * content (not semantic search); {@code limit} caps the count (0 = server
     * default). The argument key on the wire is {@code space}. This is distinct
     * from {@code noetic.query}, which is a geometric divergence probe.
     */
    public FetchResult fetch(String spaceId, String query, int limit) {
        String sid = requireSession();
        Map<String, Object> args = new LinkedHashMap<>();
        args.put("sessionId", sid);
        args.put("space", spaceId);
        if (query != null && !query.isEmpty()) {
            args.put("query", query);
        }
        if (limit > 0) {
            args.put("limit", limit);
        }
        JsonNode data = call("noetic.fetch", args);
        return new FetchResult(
                data.path("space").asText(spaceId),
                nodeList(data.get("objects")),
                data.path("matched").asInt(0),
                data.path("total").asInt(0),
                data.path("returnedTokens").asInt(0),
                data);
    }

    // -- sharing ----------------------------------------------------------- //

    /** Grant another agent {@code read}+{@code quote} on a space you own. */
    public GrantResult grantAccess(String spaceId, String subjectPrincipal) {
        return grantAccess(spaceId, subjectPrincipal, DEFAULT_GRANT_RIGHTS, null);
    }

    /** Grant another agent the given rights on a space you own. */
    public GrantResult grantAccess(String spaceId, String subjectPrincipal, List<String> rights) {
        return grantAccess(spaceId, subjectPrincipal, rights, null);
    }

    /**
     * Grant another agent scoped access to a space you own.
     *
     * <p>{@code rights} are content rights ({@code read}/{@code write}/{@code
     * quote}/{@code share}/{@code export}/...). {@code worldMutation} is the
     * separate mutation ladder ({@code read}/{@code propose}/{@code mutate});
     * leave it {@code null} and the server derives it from the rights (granting
     * {@code write} confers {@code mutate}). {@code subjectPrincipal} is the
     * grantee's {@code agentId}.
     *
     * <p>The space argument is named {@code resource} on the wire (not
     * {@code space}).
     */
    public GrantResult grantAccess(
            String spaceId, String subjectPrincipal, List<String> rights, String worldMutation) {
        String sid = requireSession();
        Map<String, Object> args = new LinkedHashMap<>();
        args.put("sessionId", sid);
        args.put("subjectPrincipal", subjectPrincipal);
        // The server names the space argument `resource`. `space` is sent too as
        // a harmless alias for older builds; unknown fields are ignored.
        args.put("resource", spaceId);
        args.put("space", spaceId);
        args.put("rights", rights == null ? new ArrayList<>(DEFAULT_GRANT_RIGHTS) : new ArrayList<>(rights));
        if (worldMutation != null) {
            args.put("worldMutation", worldMutation);
        }
        JsonNode data = call("noetic.grant", args);
        return grantResult(data);
    }

    /** Revoke a previously granted capability (immediate, forward-only). */
    public JsonNode revokeAccess(String capabilityRef) {
        String sid = requireSession();
        Map<String, Object> args = new LinkedHashMap<>();
        args.put("sessionId", sid);
        args.put("capabilityRef", capabilityRef);
        return call("noetic.revoke", args);
    }

    /** Ask the owner of a remote space for scoped access (consumer side). */
    public JsonNode requestAccess(String spaceId, List<String> rights) {
        return requestAccess(spaceId, rights, "");
    }

    /**
     * Ask the owner of a remote space for scoped access (consumer side).
     *
     * <p>The rights argument is named {@code rights} on the wire (not
     * {@code requestedRights}); the space argument is {@code space}.
     */
    public JsonNode requestAccess(String spaceId, List<String> rights, String reason) {
        String sid = requireSession();
        Map<String, Object> args = new LinkedHashMap<>();
        args.put("sessionId", sid);
        args.put("space", spaceId);
        args.put("rights", rights == null ? new ArrayList<String>() : new ArrayList<>(rights));
        if (reason != null && !reason.isEmpty()) {
            args.put("reason", reason);
        }
        return call("noetic.request_access", args);
    }

    /** List pending access requests on spaces you own (owner side). */
    public List<JsonNode> listRequests() {
        String sid = requireSession();
        JsonNode data = call("noetic.list_requests", Map.of("sessionId", sid));
        return nodeList(data.get("requests"));
    }

    /** Approve a pending access request with its requested rights (owner side). */
    public GrantResult approveRequest(String requestId) {
        return approveRequest(requestId, null, null);
    }

    /** Approve a pending access request, minting the grant (owner side). */
    public GrantResult approveRequest(String requestId, List<String> rights, String worldMutation) {
        String sid = requireSession();
        Map<String, Object> args = new LinkedHashMap<>();
        args.put("sessionId", sid);
        args.put("requestId", requestId);
        if (rights != null) {
            args.put("rights", new ArrayList<>(rights));
        }
        if (worldMutation != null) {
            args.put("worldMutation", worldMutation);
        }
        JsonNode data = call("noetic.approve_request", args);
        return grantResult(data);
    }

    /** Deny a pending access request (owner side). */
    public JsonNode denyRequest(String requestId) {
        String sid = requireSession();
        Map<String, Object> args = new LinkedHashMap<>();
        args.put("sessionId", sid);
        args.put("requestId", requestId);
        return call("noetic.deny_request", args);
    }

    // -- discovery + introspection ----------------------------------------- //

    /** List publicly discoverable spaces (no session required). */
    public List<JsonNode> discover() {
        return discover("", 0);
    }

    /** List publicly discoverable spaces matching {@code query} (no session required). */
    public List<JsonNode> discover(String query) {
        return discover(query, 0);
    }

    /** List publicly discoverable spaces (no session required). */
    public List<JsonNode> discover(String query, int limit) {
        Map<String, Object> args = new LinkedHashMap<>();
        if (query != null && !query.isEmpty()) {
            args.put("query", query);
        }
        if (limit > 0) {
            args.put("limit", limit);
        }
        JsonNode data = call("noetic.discover", args);
        return nodeList(data.get("spaces"));
    }

    /** Set a space's discovery visibility to {@code "public"}. */
    public JsonNode publish(String spaceId) {
        return publish(spaceId, "public");
    }

    /** Set a space's discovery visibility. */
    public JsonNode publish(String spaceId, String visibility) {
        String sid = requireSession();
        Map<String, Object> args = new LinkedHashMap<>();
        args.put("sessionId", sid);
        args.put("space", spaceId);
        args.put("visibility", visibility == null ? "public" : visibility);
        return call("noetic.publish", args);
    }

    /** Return scope/account/space usage metrics for the session. */
    public JsonNode metrics() {
        String sid = requireSession();
        return call("noetic.metrics", Map.of("sessionId", sid));
    }

    // -- helpers ----------------------------------------------------------- //

    private static GrantResult grantResult(JsonNode data) {
        return new GrantResult(
                data.path("capabilityRef").asText(""),
                data.path("subject").asText(""),
                data.path("resource").asText(""),
                stringList(data.get("effectiveRights")),
                data);
    }

    private static String requireText(JsonNode data, String field, String method) {
        JsonNode n = data.get(field);
        if (n == null || !n.isTextual() || n.asText().isEmpty()) {
            throw new ACNTransportError(
                    method + " response missing '" + field + "': " + truncate(data.toString(), 300),
                    method);
        }
        return n.asText();
    }

    private static List<String> stringList(JsonNode arr) {
        if (arr == null || !arr.isArray()) {
            return List.of();
        }
        List<String> out = new ArrayList<>(arr.size());
        for (JsonNode n : arr) {
            out.add(n.asText());
        }
        return out;
    }

    private static List<JsonNode> nodeList(JsonNode arr) {
        if (arr == null || !arr.isArray()) {
            return List.of();
        }
        List<JsonNode> out = new ArrayList<>(arr.size());
        for (JsonNode n : arr) {
            out.add(n);
        }
        return out;
    }

    private static String truncate(String s, int max) {
        if (s == null) {
            return "";
        }
        return s.length() <= max ? s : s.substring(0, max);
    }
}
