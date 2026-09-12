import Foundation

#if canImport(FoundationNetworking)
// On Linux, URLSession lives in a separate module.
import FoundationNetworking
#endif

/// An async client for the Priostack Agent Context Network (ACN).
///
/// The ACN is a Model Context Protocol (MCP) server reached over JSON-RPC 2.0.
/// An agent self-registers, opens a session with the returned bearer token,
/// creates isolated context spaces, stores typed facts, reads them back, and
/// shares them with other agents through scoped capability grants.
///
/// This client speaks the exact wire contract of the live server: it unwraps
/// the MCP `result.content[0].text` envelope, throws a typed ``ACNError`` on
/// tool-level denials, reuses one pooled `URLSession`, and captures the session
/// id automatically on ``connect(token:maxResponseTokens:)``.
///
/// It is an `actor`, so it is safe to share one client across concurrent tasks;
/// the JSON-RPC id counter and the captured token/session are serialised.
///
/// ```swift
/// let acn = ACNClient()
/// try await acn.register(displayName: "my-agent")   // token captured internally
/// try await acn.connect()                           // session id captured internally
/// let space = try await acn.createSpace(displayName: "prod-memory")
/// try await acn.store(space: space.spaceId, objects: [
///     ContextObject(content: "Refunds over $500 need manager approval.", type: .declaration),
/// ])
/// let hits = try await acn.fetch(space: space.spaceId, query: "refund")
/// hits.contents.forEach { print($0) }
/// ```
public actor ACNClient {
    /// Canonical MCP endpoint (Streamable HTTP). `/acn/rpc` is a working alias.
    public static let defaultEndpoint = URL(string: "https://priostack.com/mcp")!

    /// Client version, reported in the `User-Agent` header.
    public static let version = "0.3.0"

    /// The RPC endpoint this client targets.
    public nonisolated let endpoint: URL

    /// The bearer token captured by ``register(displayName:)`` (or supplied to
    /// the initialiser). Sent by ``connect(token:maxResponseTokens:)``.
    public private(set) var token: String?

    /// The session id captured by ``connect(token:maxResponseTokens:)``.
    public private(set) var sessionId: String?

    private let http: URLSession
    private var nextId = 1

    /// Create a client.
    ///
    /// - Parameters:
    ///   - endpoint: Base RPC URL. Defaults to ``defaultEndpoint``.
    ///   - token: A previously issued bearer token, to reconnect an existing
    ///     agent without registering again. Optional; ``register(displayName:)``
    ///     sets it.
    ///   - timeout: Per-request timeout in seconds, applied to every call.
    ///   - session: Inject a pre-built `URLSession` (custom proxy/TLS). When
    ///     omitted, a pooled default session is created.
    public init(
        endpoint: URL = ACNClient.defaultEndpoint,
        token: String? = nil,
        timeout: TimeInterval = 30,
        session: URLSession? = nil
    ) {
        self.endpoint = endpoint
        self.token = token
        if let session {
            self.http = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = timeout
            configuration.timeoutIntervalForResource = timeout
            configuration.httpAdditionalHeaders = [
                "Content-Type": "application/json",
                // Ask for a plain JSON reply; the Streamable-HTTP endpoint would
                // otherwise be free to answer a POST as a one-shot SSE frame.
                "Accept": "application/json",
                "User-Agent": "priostack-swift/\(ACNClient.version)",
            ]
            self.http = URLSession(configuration: configuration)
        }
    }

    /// Whether a session id has been captured.
    public var connected: Bool { sessionId != nil }

    // MARK: - Transport

    /// Invoke any `noetic.*` tool and return its unwrapped `data` value.
    ///
    /// This is the low-level escape hatch behind every typed method — use it to
    /// reach tools this client does not wrap explicitly. It performs the full
    /// round trip: builds the JSON-RPC `tools/call` envelope, unwraps
    /// `result.content[0].text`, and throws an ``ACNToolError`` when the tool
    /// returns `ok: false` (or an ``ACNTransportError`` on any protocol fault).
    ///
    /// The returned value is the envelope's `data`; an absent or `null` `data`
    /// is normalised to an empty object so subscripting stays safe.
    @discardableResult
    public func call(_ method: String, arguments: [String: JSONValue] = [:]) async throws -> JSONValue {
        let id = nextId
        nextId += 1

        let request = JSONRPCRequest(id: id, params: .init(name: method, arguments: .object(arguments)))
        let body: Data
        do {
            body = try JSONEncoder().encode(request)
        } catch {
            throw ACNTransportError("could not encode request for \(method): \(error)", method: method)
        }

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = body
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await http.data(for: urlRequest)
        } catch {
            throw ACNTransportError("network error calling \(method): \(error.localizedDescription)", method: method)
        }

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode >= 400 {
            throw ACNTransportError(
                "HTTP \(httpResponse.statusCode) calling \(method): \(Self.snippet(data))",
                method: method,
                httpStatus: httpResponse.statusCode
            )
        }

        let rpc: JSONRPCResponse
        do {
            rpc = try JSONDecoder().decode(JSONRPCResponse.self, from: data)
        } catch {
            throw ACNTransportError("non-JSON response calling \(method): \(Self.snippet(data))", method: method)
        }

        // JSON-RPC protocol error (unknown method, bad params) — no result.
        if let rpcError = rpc.error {
            throw ACNTransportError(
                "JSON-RPC error calling \(method): \(rpcError.message ?? "unknown error")",
                method: method,
                code: rpcError.code
            )
        }

        guard let result = rpc.result else {
            throw ACNTransportError("malformed response calling \(method): no result", method: method)
        }

        let envelope = try Self.unwrap(result, method: method)

        guard envelope.ok else {
            throw ACNToolError(
                outcome: ACNOutcome(rawValue: envelope.outcome),
                detail: envelope.detail ?? "",
                method: method,
                data: envelope.data
            )
        }

        switch envelope.data {
        case .none, .some(.null):
            return .object([:])
        case .some(let value):
            return value
        }
    }

    /// Parse the MCP `content[0].text` JSON envelope out of a result.
    private static func unwrap(_ result: JSONRPCResponse.RPCResult, method: String) throws -> Envelope {
        guard let first = result.content?.first else {
            throw ACNTransportError("response for \(method) had no content block", method: method)
        }
        guard let text = first.text else {
            throw ACNTransportError("response for \(method) had no text payload", method: method)
        }
        guard let textData = text.data(using: .utf8) else {
            throw ACNTransportError("response for \(method) had a non-UTF8 text payload", method: method)
        }
        do {
            return try JSONDecoder().decode(Envelope.self, from: textData)
        } catch {
            throw ACNTransportError("could not decode envelope for \(method): \(Self.snippet(textData))", method: method)
        }
    }

    /// Decode a typed result from an unwrapped `data` value, mapping any
    /// decoding failure to a transport error (a shape surprise, not a denial).
    private func decode<T: Decodable>(_ type: T.Type, from data: JSONValue, method: String) throws -> T {
        do {
            return try data.decoded(as: T.self)
        } catch {
            throw ACNTransportError("could not decode \(T.self) from \(method) response: \(error)", method: method)
        }
    }

    private func requireSession() throws -> String {
        guard let sessionId else {
            throw ACNTransportError("no active session: call connect() first")
        }
        return sessionId
    }

    private static func snippet(_ data: Data, limit: Int = 500) -> String {
        let text = String(data: data, encoding: .utf8) ?? "<\(data.count) bytes>"
        return text.count > limit ? String(text.prefix(limit)) : text
    }

    // MARK: - Identity

    /// Self-register a new agent and capture its bearer token.
    ///
    /// Only available on the online multi-agent ACN. The token is shown once;
    /// it is stored on this client (``token``) and returned so you can persist
    /// it for future sessions. Throws an ``ACNToolError`` with
    /// ``ACNOutcome/notImplemented`` on a single-tenant ACN.
    @discardableResult
    public func register(displayName: String = "agent") async throws -> RegisterResult {
        let data = try await call("noetic.register", arguments: ["displayName": .string(displayName)])
        var result = try decode(RegisterResult.self, from: data, method: "noetic.register")
        guard !result.token.isEmpty else {
            throw ACNTransportError("register returned no token: \(data)", method: "noetic.register")
        }
        result.raw = data
        token = result.token
        return result
    }

    /// Open a session with a bearer token and capture the session id.
    ///
    /// Pass `token` explicitly, or rely on the token captured by
    /// ``register(displayName:)`` / passed to the initialiser. Re-call after
    /// being granted access to a space so the widened scope is applied.
    ///
    /// - Important: the envelope `data` uses PascalCase Go field names; the
    ///   session id is read from `SessionID` (see ``ConnectResult``).
    @discardableResult
    public func connect(token: String? = nil, maxResponseTokens: Int = 4096) async throws -> ConnectResult {
        guard let tok = token ?? self.token else {
            throw ACNTransportError("connect() needs a token: register() first or pass token:")
        }
        let data = try await call(
            "noetic.connect",
            arguments: ["token": .string(tok), "maxResponseTokens": .int(maxResponseTokens)]
        )
        var result = try decode(ConnectResult.self, from: data, method: "noetic.connect")
        guard !result.sessionId.isEmpty else {
            throw ACNTransportError("connect returned no SessionID: \(data)", method: "noetic.connect")
        }
        result.raw = data
        sessionId = result.sessionId
        self.token = tok
        return result
    }

    /// End the current session. Durable facts are **not** revoked.
    @discardableResult
    public func disconnect() async throws -> JSONValue {
        let sid = try requireSession()
        let data = try await call("noetic.disconnect", arguments: ["sessionId": .string(sid)])
        sessionId = nil
        return data
    }

    /// Mint a fresh bearer token for this agent and retire the old one.
    ///
    /// Existing sessions keep working; use the new token for future `connect`
    /// calls. The new token is stored on this client and returned.
    @discardableResult
    public func rotateToken() async throws -> String {
        let sid = try requireSession()
        let data = try await call("noetic.rotate_token", arguments: ["sessionId": .string(sid)])
        guard let newToken = data["token"]?.stringValue, !newToken.isEmpty else {
            throw ACNTransportError("rotate_token returned no token: \(data)", method: "noetic.rotate_token")
        }
        token = newToken
        return newToken
    }

    /// Discover the grantable rights + world-mutation vocabulary in scope.
    @discardableResult
    public func capabilities() async throws -> JSONValue {
        let sid = try requireSession()
        return try await call("noetic.capabilities", arguments: ["sessionId": .string(sid)])
    }

    // MARK: - Spaces + facts

    /// Create an isolated context space and return its resolved id.
    ///
    /// `defaultRights` is the ceiling of rights the space may offer to others;
    /// it does not grant anything by itself. Use the **returned** `spaceId` for
    /// subsequent writes and reads.
    @discardableResult
    public func createSpace(
        displayName: String,
        defaultRights: [String]? = nil,
        visibility: String? = nil,
        persistenceMode: String? = nil,
        protectionLevel: String? = nil
    ) async throws -> SpaceResult {
        let sid = try requireSession()
        var args: [String: JSONValue] = ["sessionId": .string(sid), "displayName": .string(displayName)]
        if let defaultRights { args["defaultRights"] = .array(defaultRights.map(JSONValue.string)) }
        if let visibility { args["visibility"] = .string(visibility) }
        if let persistenceMode { args["persistenceMode"] = .string(persistenceMode) }
        if let protectionLevel { args["protectionLevel"] = .string(protectionLevel) }
        let data = try await call("noetic.create_space", arguments: args)
        var result = try decode(SpaceResult.self, from: data, method: "noetic.create_space")
        guard !result.spaceId.isEmpty else {
            throw ACNTransportError("create_space returned no spaceId: \(data)", method: "noetic.create_space")
        }
        result.raw = data
        return result
    }

    /// Persist typed facts into a space.
    ///
    /// Writing needs the write right and the `mutate` capability; the space
    /// owner has both. The `space` argument is the space id.
    @discardableResult
    public func store(space spaceId: String, objects: [ContextObject]) async throws -> StoreResult {
        let sid = try requireSession()
        let data = try await call("noetic.store", arguments: [
            "sessionId": .string(sid),
            "space": .string(spaceId),
            "objects": .array(objects.map(\.jsonValue)),
        ])
        var result = try decode(StoreResult.self, from: data, method: "noetic.store")
        result.raw = data
        return result
    }

    /// Read stored objects back from a space (the content reader).
    ///
    /// `query` is a case-insensitive **substring** filter over content (not
    /// semantic search); `limit` caps the count (0 = server default). The
    /// `space` argument is the space id.
    @discardableResult
    public func fetch(space spaceId: String, query: String = "", limit: Int = 0) async throws -> FetchResult {
        let sid = try requireSession()
        var args: [String: JSONValue] = ["sessionId": .string(sid), "space": .string(spaceId)]
        if !query.isEmpty { args["query"] = .string(query) }
        if limit != 0 { args["limit"] = .int(limit) }
        let data = try await call("noetic.fetch", arguments: args)
        var result = try decode(FetchResult.self, from: data, method: "noetic.fetch")
        if result.space.isEmpty { result.space = spaceId }
        result.raw = data
        return result
    }

    // MARK: - Sharing

    /// Grant another agent scoped access to a space you own.
    ///
    /// - Parameters:
    ///   - spaceId: the space to share. **Sent as the `resource` argument** the
    ///     server expects (a harmless `space` alias is also sent for old builds).
    ///   - subjectPrincipal: the grantee's `agentId`.
    ///   - rights: content rights (`read`/`write`/`quote`/`share`/`export`/…).
    ///   - worldMutation: the separate mutation ladder (`read`/`propose`/
    ///     `mutate`); leave `nil` and the server derives it from `rights`
    ///     (granting `write` confers `mutate`).
    @discardableResult
    public func grantAccess(
        space spaceId: String,
        subjectPrincipal: String,
        rights: [String] = ["read", "quote"],
        worldMutation: String? = nil,
        persistenceMode: String? = nil
    ) async throws -> GrantResult {
        let sid = try requireSession()
        var args: [String: JSONValue] = [
            "sessionId": .string(sid),
            "subjectPrincipal": .string(subjectPrincipal),
            "resource": .string(spaceId),
            "space": .string(spaceId),
            "rights": .array(rights.map(JSONValue.string)),
        ]
        if let worldMutation { args["worldMutation"] = .string(worldMutation) }
        if let persistenceMode { args["persistenceMode"] = .string(persistenceMode) }
        let data = try await call("noetic.grant", arguments: args)
        return try grantResult(from: data, method: "noetic.grant")
    }

    /// Revoke a previously granted capability (immediate, forward-only).
    @discardableResult
    public func revokeAccess(capabilityRef: String) async throws -> JSONValue {
        let sid = try requireSession()
        return try await call("noetic.revoke", arguments: [
            "sessionId": .string(sid),
            "capabilityRef": .string(capabilityRef),
        ])
    }

    /// Ask the owner of a remote space for scoped access (consumer side).
    ///
    /// The `space` argument is the space id; the rights argument is named
    /// **`rights`** (not `requestedRights`).
    @discardableResult
    public func requestAccess(
        space spaceId: String,
        rights: [String],
        persistenceMode: String? = nil,
        reason: String = ""
    ) async throws -> JSONValue {
        let sid = try requireSession()
        var args: [String: JSONValue] = [
            "sessionId": .string(sid),
            "space": .string(spaceId),
            "rights": .array(rights.map(JSONValue.string)),
        ]
        if let persistenceMode { args["persistenceMode"] = .string(persistenceMode) }
        if !reason.isEmpty { args["reason"] = .string(reason) }
        return try await call("noetic.request_access", arguments: args)
    }

    /// List pending access requests on spaces you own (owner side).
    public func listRequests() async throws -> [JSONValue] {
        let sid = try requireSession()
        let data = try await call("noetic.list_requests", arguments: ["sessionId": .string(sid)])
        return data["requests"]?.arrayValue ?? []
    }

    /// Approve a pending access request, minting the grant (owner side).
    @discardableResult
    public func approveRequest(
        requestId: String,
        rights: [String]? = nil,
        worldMutation: String? = nil,
        persistenceMode: String? = nil
    ) async throws -> GrantResult {
        let sid = try requireSession()
        var args: [String: JSONValue] = ["sessionId": .string(sid), "requestId": .string(requestId)]
        if let rights { args["rights"] = .array(rights.map(JSONValue.string)) }
        if let worldMutation { args["worldMutation"] = .string(worldMutation) }
        if let persistenceMode { args["persistenceMode"] = .string(persistenceMode) }
        let data = try await call("noetic.approve_request", arguments: args)
        return try grantResult(from: data, method: "noetic.approve_request")
    }

    /// Deny a pending access request (owner side).
    @discardableResult
    public func denyRequest(requestId: String) async throws -> JSONValue {
        let sid = try requireSession()
        return try await call("noetic.deny_request", arguments: [
            "sessionId": .string(sid),
            "requestId": .string(requestId),
        ])
    }

    private func grantResult(from data: JSONValue, method: String) throws -> GrantResult {
        var result = try decode(GrantResult.self, from: data, method: method)
        result.raw = data
        return result
    }

    // MARK: - Discovery + introspection

    /// List publicly discoverable spaces (no session required).
    public func discover(query: String = "", limit: Int = 0) async throws -> [JSONValue] {
        var args: [String: JSONValue] = [:]
        if !query.isEmpty { args["query"] = .string(query) }
        if limit != 0 { args["limit"] = .int(limit) }
        let data = try await call("noetic.discover", arguments: args)
        return data["spaces"]?.arrayValue ?? []
    }

    /// Set a space's discovery visibility.
    @discardableResult
    public func publish(space spaceId: String, visibility: String = "public") async throws -> JSONValue {
        let sid = try requireSession()
        return try await call("noetic.publish", arguments: [
            "sessionId": .string(sid),
            "space": .string(spaceId),
            "visibility": .string(visibility),
        ])
    }

    /// Return scope/account/space usage metrics for the session.
    @discardableResult
    public func metrics() async throws -> JSONValue {
        let sid = try requireSession()
        return try await call("noetic.metrics", arguments: ["sessionId": .string(sid)])
    }
}

// MARK: - Wire types (JSON-RPC 2.0 framing)

private struct JSONRPCRequest: Encodable {
    let jsonrpc = "2.0"
    let id: Int
    let method = "tools/call"
    let params: Params

    struct Params: Encodable {
        let name: String
        let arguments: JSONValue
    }
}

private struct JSONRPCResponse: Decodable {
    let result: RPCResult?
    let error: RPCError?

    struct RPCError: Decodable {
        let code: Int?
        let message: String?
    }

    struct RPCResult: Decodable {
        let content: [ContentBlock]?
        let isError: Bool?
    }

    struct ContentBlock: Decodable {
        let type: String?
        let text: String?
    }
}

/// The tool envelope carried as a JSON string in `result.content[0].text`.
private struct Envelope: Decodable {
    let ok: Bool
    let outcome: String
    let detail: String?
    let data: JSONValue?

    private enum CodingKeys: String, CodingKey {
        case ok, outcome, detail, data
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = try c.decodeIfPresent(Bool.self, forKey: .ok) ?? false
        outcome = try c.decodeIfPresent(String.self, forKey: .outcome) ?? ""
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
        data = try c.decodeIfPresent(JSONValue.self, forKey: .data)
    }
}
