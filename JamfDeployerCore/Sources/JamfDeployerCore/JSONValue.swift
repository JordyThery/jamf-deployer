import Foundation

/// A generic JSON value, used for plan `before`/`after` payloads whose shape
/// depends on the resource type.
public nonisolated enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

nonisolated extension JSONValue: Decodable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }
}

nonisolated extension JSONValue {
    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    /// Block-setting encoding for primitive values ("true"/"false", trimmed
    /// numbers, raw strings); nil for arrays, objects and null.
    public var settingValue: String? {
        switch self {
        case .bool(let value): value ? "true" : "false"
        case .number(let value): Self.numberText(value)
        case .string(let value): value
        case .null, .array, .object: nil
        }
    }

    /// Whole numbers render without a decimal point; magnitudes beyond Int
    /// range fall back to the plain Double rendering instead of trapping.
    static func numberText(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 9_007_199_254_740_992 {
            return String(Int(value))
        }
        return String(value)
    }

    /// Short human-readable rendering for diff rows.
    public var displayText: String {
        switch self {
        case .null: "—"
        case .bool(let value): value ? "on" : "off"
        case .number(let value): Self.numberText(value)
        case .string(let value): value.isEmpty ? "(empty)" : value
        case .array(let values): "[\(values.count) item\(values.count == 1 ? "" : "s")]"
        case .object: "{…}"
        }
    }
}
