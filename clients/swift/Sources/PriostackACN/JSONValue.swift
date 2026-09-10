import Foundation

/// A fully general JSON value.
///
/// The ACN wire protocol carries free-form JSON in a handful of places — the
/// `arguments` map of a `tools/call`, the tool envelope's `data` payload, and
/// nested objects such as stored-object references. `JSONValue` models all of
/// it with a single `Codable`, `Sendable` enum so those payloads round-trip
/// losslessly without forcing a bespoke `struct` for every shape.
///
/// Literals make building call arguments concise:
/// ```swift
/// let args: [String: JSONValue] = ["limit": 10, "query": "refund"]
/// ```
/// and the accessors (`stringValue`, `intValue`, subscripts, …) make reading a
/// dynamic response ergonomic:
/// ```swift
/// let spaces = data["spaces"]?.arrayValue ?? []
/// ```
public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    // MARK: Decoding

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "value is not representable as JSON"
            )
        }
    }

    // MARK: Encoding

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    // MARK: Typed accessors

    /// The wrapped string, or `nil` if this value is not a string.
    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    /// The wrapped integer, coercing a whole `double` when needed.
    public var intValue: Int? {
        switch self {
        case .int(let value): return value
        case .double(let value): return Int(value)
        default: return nil
        }
    }

    /// The wrapped number as a `Double`, coercing an `int` when needed.
    public var doubleValue: Double? {
        switch self {
        case .double(let value): return value
        case .int(let value): return Double(value)
        default: return nil
        }
    }

    /// The wrapped boolean, or `nil` if this value is not a boolean.
    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    /// The wrapped array, or `nil` if this value is not an array.
    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    /// The wrapped object, or `nil` if this value is not an object.
    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    /// Whether this value is JSON `null`.
    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// Member of a JSON object, or `nil` for a missing key / non-object.
    public subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    /// Element of a JSON array, or `nil` for an out-of-range index / non-array.
    public subscript(index: Int) -> JSONValue? {
        if case .array(let array) = self, array.indices.contains(index) {
            return array[index]
        }
        return nil
    }

    // MARK: Bridging to typed models

    /// Re-decode this value into a concrete `Decodable` type.
    ///
    /// The tool envelope's `data` arrives as a `JSONValue`; the typed result
    /// structs re-decode from it so their `CodingKeys` (notably the PascalCase
    /// `connect` keys) do the field mapping in one place.
    public func decoded<T: Decodable>(as type: T.Type = T.self) throws -> T {
        let data = try JSONEncoder().encode(self)
        return try JSONDecoder().decode(T.self, from: data)
    }
}

// MARK: - Literal conveniences

extension JSONValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .int(value) }
}

extension JSONValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .double(value) }
}

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension JSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

extension JSONValue: CustomStringConvertible {
    /// Compact JSON text, for logging and error messages.
    public var description: String {
        guard
            let data = try? JSONEncoder().encode(self),
            let text = String(data: data, encoding: .utf8)
        else {
            return "<unencodable JSON>"
        }
        return text
    }
}
