import Foundation

/// A permissive JSON tree.
///
/// Hook payloads are defined by Claude Code, not by us, and they gain fields between
/// releases. Decoding into a fixed struct would throw the moment that happens, so we
/// keep the whole payload as a tree and pull typed values out of it by key. Unknown
/// fields ride along harmlessly.
public enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "unrepresentable JSON")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let dict) = self { return dict[key] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let v) = self { return v }
        return nil
    }

    public var doubleValue: Double? {
        switch self {
        case .number(let v): return v
        case .string(let v): return Double(v)
        default: return nil
        }
    }

    public var intValue: Int? { doubleValue.map(Int.init) }

    public var boolValue: Bool? {
        if case .bool(let v) = self { return v }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let v) = self { return v }
        return nil
    }

    /// `model` arrives as a bare string on some events and as `{id, display_name}` on
    /// others. Collapse both to something printable.
    public var displayString: String? {
        switch self {
        case .string(let v): return v
        case .object: return self["display_name"]?.stringValue ?? self["id"]?.stringValue
        default: return nil
        }
    }
}
