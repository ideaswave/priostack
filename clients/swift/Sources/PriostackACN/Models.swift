import Foundation

/// The `type` of a stored context object.
///
/// The `store` tool accepts only these three kinds; anything else is rejected
/// server-side with `invalid-query`. (Proposals/inferences go through the
/// propose/commit path, not `store`.)
public enum ObjectKind: String, Codable, CaseIterable, Sendable {
    case declaration
    case observation
    case measurement
}

/// A typed fact to persist into a space via ``ACNClient/store(space:objects:)``.
public struct ContextObject: Sendable, Equatable {
    /// The fact text.
    public var content: String
    /// The fact kind. Defaults to ``ObjectKind/declaration``.
    public var type: ObjectKind
    /// Optional provenance references.
    public var provenance: [String]?

    public init(content: String, type: ObjectKind = .declaration, provenance: [String]? = nil) {
        self.content = content
        self.type = type
        self.provenance = provenance
    }

    /// Wire form: `{"content": ..., "type": ..., "provenance"?: [...]}`.
    var jsonValue: JSONValue {
        var object: [String: JSONValue] = [
            "content": .string(content),
            "type": .string(type.rawValue),
        ]
        if let provenance, !provenance.isEmpty {
            object["provenance"] = .array(provenance.map(JSONValue.string))
        }
        return .object(object)
    }
}

// MARK: - Result models
//
// The server returns plain JSON. These lightweight structs give ergonomic,
// type-checked access to the common calls while still exposing the full raw
// `data` value via `.raw` for anything not surfaced as a property. Each uses a
// tolerant `init(from:)` so a missing optional field defaults rather than
// failing the whole decode.

/// Result of ``ACNClient/register(displayName:)``.
public struct RegisterResult: Decodable, Sendable {
    public let token: String
    public let agentId: String
    public let accountId: String
    public let tier: String
    public internal(set) var raw: JSONValue = .object([:])

    private enum CodingKeys: String, CodingKey {
        case token, agentId, accountId, tier
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        token = try c.decodeIfPresent(String.self, forKey: .token) ?? ""
        agentId = try c.decodeIfPresent(String.self, forKey: .agentId) ?? ""
        accountId = try c.decodeIfPresent(String.self, forKey: .accountId) ?? ""
        tier = try c.decodeIfPresent(String.self, forKey: .tier) ?? ""
    }
}

/// Result of ``ACNClient/connect(token:maxResponseTokens:)``.
///
/// - Important: the `connect` envelope's `data` uses **PascalCase** Go field
///   names (`SessionID`, `ResolvedAccount`, …). The `CodingKeys` below map them
///   to Swift-cased properties. Every other tool uses lowercase keys.
public struct ConnectResult: Decodable, Sendable {
    public let sessionId: String
    public let resolvedAccount: String
    public let grantedCapabilities: [String]
    public let grantedContextRights: [String]
    public let boundSpace: String
    public let resolvedMaxTokens: Int
    public internal(set) var raw: JSONValue = .object([:])

    private enum CodingKeys: String, CodingKey {
        case sessionId = "SessionID"
        case resolvedAccount = "ResolvedAccount"
        case grantedCapabilities = "GrantedCapabilities"
        case grantedContextRights = "GrantedContextRights"
        case boundSpace = "BoundSpace"
        case resolvedMaxTokens = "ResolvedMaxTokens"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try c.decodeIfPresent(String.self, forKey: .sessionId) ?? ""
        resolvedAccount = try c.decodeIfPresent(String.self, forKey: .resolvedAccount) ?? ""
        grantedCapabilities = try c.decodeIfPresent([String].self, forKey: .grantedCapabilities) ?? []
        grantedContextRights = try c.decodeIfPresent([String].self, forKey: .grantedContextRights) ?? []
        boundSpace = try c.decodeIfPresent(String.self, forKey: .boundSpace) ?? ""
        resolvedMaxTokens = try c.decodeIfPresent(Int.self, forKey: .resolvedMaxTokens) ?? 0
    }
}

/// Result of ``ACNClient/createSpace(displayName:defaultRights:visibility:persistenceMode:protectionLevel:)``.
public struct SpaceResult: Decodable, Sendable {
    public let spaceId: String
    public let accountId: String
    public let persistenceMode: String
    public let protectionLevel: String
    public internal(set) var raw: JSONValue = .object([:])

    private enum CodingKeys: String, CodingKey {
        case spaceId, accountId, persistenceMode, protectionLevel
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        spaceId = try c.decodeIfPresent(String.self, forKey: .spaceId) ?? ""
        accountId = try c.decodeIfPresent(String.self, forKey: .accountId) ?? ""
        persistenceMode = try c.decodeIfPresent(String.self, forKey: .persistenceMode) ?? ""
        protectionLevel = try c.decodeIfPresent(String.self, forKey: .protectionLevel) ?? ""
    }
}

/// Result of ``ACNClient/store(space:objects:)``.
public struct StoreResult: Decodable, Sendable {
    /// Raw object-reference records the server minted for the stored objects.
    public let objectRefs: [JSONValue]
    public internal(set) var raw: JSONValue = .object([:])

    /// How many objects were ingested.
    public var count: Int { objectRefs.count }

    private enum CodingKeys: String, CodingKey {
        case objectRefs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        objectRefs = try c.decodeIfPresent([JSONValue].self, forKey: .objectRefs) ?? []
    }
}

/// A single object returned by ``ACNClient/fetch(space:query:limit:)``.
public struct FetchedObject: Decodable, Sendable {
    public let objectRef: String
    public let kind: String
    public let content: String
    public let tokens: Int

    private enum CodingKeys: String, CodingKey {
        case objectRef, kind, content, tokens
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        objectRef = try c.decodeIfPresent(String.self, forKey: .objectRef) ?? ""
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        content = try c.decodeIfPresent(String.self, forKey: .content) ?? ""
        tokens = try c.decodeIfPresent(Int.self, forKey: .tokens) ?? 0
    }
}

/// Result of ``ACNClient/fetch(space:query:limit:)`` — the content reader.
public struct FetchResult: Decodable, Sendable {
    public internal(set) var space: String
    public let objects: [FetchedObject]
    public let matched: Int
    public let total: Int
    public let returnedTokens: Int
    public internal(set) var raw: JSONValue = .object([:])

    /// Just the `content` strings of the returned objects.
    public var contents: [String] { objects.map(\.content) }

    private enum CodingKeys: String, CodingKey {
        case space, objects, matched, total, returnedTokens
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        space = try c.decodeIfPresent(String.self, forKey: .space) ?? ""
        objects = try c.decodeIfPresent([FetchedObject].self, forKey: .objects) ?? []
        matched = try c.decodeIfPresent(Int.self, forKey: .matched) ?? 0
        total = try c.decodeIfPresent(Int.self, forKey: .total) ?? 0
        returnedTokens = try c.decodeIfPresent(Int.self, forKey: .returnedTokens) ?? 0
    }
}

/// Result of ``ACNClient/grantAccess(space:subjectPrincipal:rights:worldMutation:persistenceMode:)``
/// and ``ACNClient/approveRequest(requestId:rights:worldMutation:persistenceMode:)``.
public struct GrantResult: Decodable, Sendable {
    public let capabilityRef: String
    public let subject: String
    public let resource: String
    public let effectiveRights: [String]
    public internal(set) var raw: JSONValue = .object([:])

    private enum CodingKeys: String, CodingKey {
        case capabilityRef, subject, resource, effectiveRights
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        capabilityRef = try c.decodeIfPresent(String.self, forKey: .capabilityRef) ?? ""
        subject = try c.decodeIfPresent(String.self, forKey: .subject) ?? ""
        resource = try c.decodeIfPresent(String.self, forKey: .resource) ?? ""
        effectiveRights = try c.decodeIfPresent([String].self, forKey: .effectiveRights) ?? []
    }
}
