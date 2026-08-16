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

/// Re-encodes a value parsed out of a CLI's JSON output, without crashing on the
/// values a top-level `JSONSerialization` write rejects.
///
/// `JSONSerialization.data(withJSONObject:)` raises an **Objective-C exception**
/// — not a Swift error — when handed anything that is not an array or a
/// dictionary. `try?` does not catch that: it terminates the process. Every
/// adapter re-encodes vendor payloads whose fields are nullable (`"input": null`
/// on a tool call that carries no arguments is ordinary output, not a
/// malformation), so the guard belongs in one place rather than at each call
/// site.
///
/// - Returns: the encoded bytes, or `nil` for JSON `null`, a missing value, or
///   anything that cannot be represented.
func jsonData(from value: Any?) -> Data? {
    guard let value, !(value is NSNull) else { return nil }

    if JSONSerialization.isValidJSONObject(value) {
        return try? JSONSerialization.data(withJSONObject: value)
    }
    // Scalars are legal JSON values but illegal top-level objects, and a CLI is
    // free to put one where a record would fit. Keeping them costs one option
    // flag and preserves information a caller might want.
    //
    // `isValidJSONObject` already rejects a NaN or an infinity *inside* a
    // container, but it only inspects containers — a bare one has to be checked
    // here, or the fragment write aborts exactly like the case above.
    if let number = value as? NSNumber, !number.doubleValue.isFinite { return nil }
    guard value is String || value is NSNumber else { return nil }
    return try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
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
