import Foundation

/// Decodes an arbitrary JSON value and keeps it as bytes.
///
/// Structured output is whatever shape the *caller's* type is, which the adapter
/// knows nothing about. Re-encoding it verbatim lets the adapter carry it
/// through to `AgentResponse.decode(as:)` without modelling it.
struct JSONPassthrough: Decodable {
    let data: Data

    init(from decoder: any Decoder) throws {
        // `JSONSerialization` is the only way back to bytes from a `Decoder`
        // holding an unknown shape, so re-encode through a single-value box.
        let container = try decoder.singleValueContainer()
        if let object = try? container.decode([String: JSONValue].self) {
            data = try JSONSerialization.data(
                withJSONObject: object.mapValues(\.rawValue),
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
        } else if let array = try? container.decode([JSONValue].self) {
            data = try JSONSerialization.data(
                withJSONObject: array.map(\.rawValue),
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Structured output was neither an object nor an array"
            )
        }
    }
}

/// A decoded JSON value, kept as Foundation types.
enum JSONValue: Decodable {
    case string(String)
    case number(Double)
    case integer(Int)
    case boolean(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    var rawValue: Any {
        switch self {
        case let .string(value): return value
        case let .number(value): return value
        case let .integer(value): return value
        case let .boolean(value): return value
        case let .array(values): return values.map(\.rawValue)
        case let .object(values): return values.mapValues(\.rawValue)
        case .null: return NSNull()
        }
    }
}
