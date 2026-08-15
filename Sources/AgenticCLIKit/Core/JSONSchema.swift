import Foundation

/// A JSON Schema, in the subset the agent CLIs actually enforce.
///
/// This is what turns "please reply with JSON" into a guarantee: all three
/// prompting CLIs accept a schema and constrain the model's final message to
/// match it, so the decode on the Swift side is checking a contract the provider
/// already enforced rather than hoping.
///
/// ```swift
/// static let outputSchema = JSONSchema.object([
///     "commitSubject": .string("Imperative mood, at most 50 characters"),
///     "commitDescription": .string("Body explaining why the change was made"),
/// ])
/// ```
///
/// Every property is required and `additionalProperties` is `false` by default,
/// because a schema that permits missing keys defeats the point — the Swift type
/// would fail to decode anyway.
public indirect enum JSONSchema: Sendable, Hashable {
    // The cases take no default arguments on purpose: with defaults they become
    // ambiguous against the convenience builders below, and `.string()` stops
    // compiling at the call site.
    case string(description: String?, enumeration: [String]?)
    case integer(description: String?)
    case number(description: String?)
    case boolean(description: String?)
    case array(of: JSONSchema, description: String?)
    case object(properties: [String: JSONSchema], required: [String], description: String?)
    /// A value that may be absent. Wraps the underlying schema and drops the
    /// property from the required list.
    case optional(JSONSchema)
    /// Hand-written schema, for anything this enum does not model.
    /// The string must be a valid JSON object.
    case raw(json: String)

    // MARK: - Ergonomic builders

    public static func string(_ description: String? = nil) -> JSONSchema {
        .string(description: description, enumeration: nil)
    }

    /// A string constrained to a fixed set of values.
    public static func string(_ description: String? = nil, oneOf values: [String]) -> JSONSchema {
        .string(description: description, enumeration: values)
    }

    public static func integer(_ description: String? = nil) -> JSONSchema {
        .integer(description: description)
    }

    public static func number(_ description: String? = nil) -> JSONSchema {
        .number(description: description)
    }

    public static func boolean(_ description: String? = nil) -> JSONSchema {
        .boolean(description: description)
    }

    public static func array(of element: JSONSchema, _ description: String? = nil) -> JSONSchema {
        .array(of: element, description: description)
    }

    /// An object whose properties are all required, unless wrapped in
    /// ``optional(_:)``.
    public static func object(_ properties: [String: JSONSchema], description: String? = nil) -> JSONSchema {
        let required = properties
            .filter { if case .optional = $0.value { return false } else { return true } }
            .keys
            .sorted()
        return .object(properties: properties, required: required, description: description)
    }
}

extension JSONSchema {
    /// The schema as a Foundation JSON object, ready to serialise.
    public func jsonObject() -> [String: Any] {
        switch self {
        case let .string(description, enumeration):
            var schema: [String: Any] = ["type": "string"]
            if let description { schema["description"] = description }
            if let enumeration { schema["enum"] = enumeration }
            return schema

        case let .integer(description):
            return Self.scalar("integer", description)

        case let .number(description):
            return Self.scalar("number", description)

        case let .boolean(description):
            return Self.scalar("boolean", description)

        case let .array(element, description):
            var schema: [String: Any] = ["type": "array", "items": element.jsonObject()]
            if let description { schema["description"] = description }
            return schema

        case let .object(properties, required, description):
            var schema: [String: Any] = [
                "type": "object",
                "properties": properties.mapValues { $0.jsonObject() },
                "required": required.sorted(),
                // Providers reject unknown keys outright, which is what keeps a
                // model from padding the object with commentary fields.
                "additionalProperties": false,
            ]
            if let description { schema["description"] = description }
            return schema

        case let .optional(wrapped):
            return wrapped.jsonObject()

        case let .raw(json):
            let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
            return object ?? ["type": "object"]
        }
    }

    private static func scalar(_ type: String, _ description: String?) -> [String: Any] {
        var schema: [String: Any] = ["type": type]
        if let description { schema["description"] = description }
        return schema
    }

    /// The schema as a compact JSON string, for CLIs that take it inline.
    ///
    /// Keys are sorted so the same schema always produces the same bytes, which
    /// keeps recorded test transcripts stable.
    public func jsonString() throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: jsonObject(),
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        return String(decoding: data, as: UTF8.self)
    }

    public func jsonData() throws -> Data {
        Data(try jsonString().utf8)
    }
}

extension JSONSchema: CustomStringConvertible {
    public var description: String {
        (try? jsonString()) ?? "<invalid schema>"
    }
}
