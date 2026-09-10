import Foundation

/// Common protocol for every error `ACNClient` can throw.
///
/// The ACN reports two very different kinds of failure and the client raises a
/// different concrete type for each, both conforming to `ACNError`:
///
/// * ``ACNTransportError`` — the request never produced a valid tool envelope
///   (network error, non-2xx HTTP status, non-JSON body, or a JSON-RPC `error`
///   object such as an unknown method or bad params).
/// * ``ACNToolError`` — the call reached the tool but the tool declined it: the
///   envelope came back with `ok: false` and an `outcome`.
///
/// Catch `ACNError` to handle anything the client can raise; catch a concrete
/// type (or switch on ``ACNToolError/outcome``) to handle one case.
public protocol ACNError: Error {
    /// A human-readable description of the failure.
    var message: String { get }
    /// The tool name (`noetic.*`) the failing call targeted, if known.
    var method: String? { get }
}

/// A network, HTTP, decoding, or JSON-RPC protocol failure.
///
/// Raised before a valid tool envelope could be obtained: connection errors,
/// timeouts, non-2xx HTTP responses, non-JSON bodies, envelopes missing the
/// `content[0].text` payload, or a JSON-RPC `error` object.
public struct ACNTransportError: ACNError, LocalizedError, CustomStringConvertible, Sendable {
    public let message: String
    public let method: String?
    /// JSON-RPC error code, when the failure was a JSON-RPC `error`.
    public let code: Int?
    /// HTTP status code, when the failure was an HTTP error.
    public let httpStatus: Int?

    public init(
        _ message: String,
        method: String? = nil,
        code: Int? = nil,
        httpStatus: Int? = nil
    ) {
        self.message = message
        self.method = method
        self.code = code
        self.httpStatus = httpStatus
    }

    public var errorDescription: String? { message }
    public var description: String { message }
}

/// The server `outcome` on a declined call (`ok: false`).
///
/// Each documented outcome is a distinct case so callers can pattern-match; an
/// unrecognised outcome degrades gracefully to ``other(_:)`` carrying the raw
/// string rather than being mis-mapped.
public enum ACNOutcome: Sendable, Equatable {
    case notFound
    case invalidQuery
    case capabilityDenied
    case policyDenied
    case requiresGovernance
    case staleBase
    case integrityFault
    case conflict
    case capacityExhausted
    case notImplemented
    case other(String)

    public init(rawValue: String) {
        switch rawValue {
        case "not-found": self = .notFound
        case "invalid-query": self = .invalidQuery
        case "capability-denied": self = .capabilityDenied
        case "policy-denied": self = .policyDenied
        case "requires-governance": self = .requiresGovernance
        case "stale-base": self = .staleBase
        case "integrity-fault": self = .integrityFault
        case "conflict": self = .conflict
        case "capacity-exhausted": self = .capacityExhausted
        // The single-tenant/offline ACN reports an unavailable tool (e.g.
        // register) as `not-implemented`.
        case "not-implemented": self = .notImplemented
        default: self = .other(rawValue)
        }
    }

    /// The wire string for this outcome.
    public var rawValue: String {
        switch self {
        case .notFound: return "not-found"
        case .invalidQuery: return "invalid-query"
        case .capabilityDenied: return "capability-denied"
        case .policyDenied: return "policy-denied"
        case .requiresGovernance: return "requires-governance"
        case .staleBase: return "stale-base"
        case .integrityFault: return "integrity-fault"
        case .conflict: return "conflict"
        case .capacityExhausted: return "capacity-exhausted"
        case .notImplemented: return "not-implemented"
        case .other(let value): return value
        }
    }
}

/// A tool declined the call (envelope `ok: false`).
///
/// Carries the server ``outcome`` and human-readable ``detail``, plus any
/// partial ``data`` the server attached to the failure.
public struct ACNToolError: ACNError, LocalizedError, CustomStringConvertible, Sendable {
    /// The server outcome (e.g. ``ACNOutcome/capabilityDenied``).
    public let outcome: ACNOutcome
    /// The server's `detail` message, if any.
    public let detail: String
    public let method: String?
    /// Any partial `data` the server attached to the failure.
    public let data: JSONValue?

    public init(
        outcome: ACNOutcome,
        detail: String,
        method: String? = nil,
        data: JSONValue? = nil
    ) {
        self.outcome = outcome
        self.detail = detail
        self.method = method
        self.data = data
    }

    public var message: String {
        if !detail.isEmpty { return detail }
        let raw = outcome.rawValue
        return raw.isEmpty ? "ACN tool error" : raw
    }

    public var errorDescription: String? { message }
    public var description: String { "ACNToolError(\(outcome.rawValue)): \(message)" }
}
