import Foundation

/// A tool with its argument and result types erased.
///
/// ``AgentTool`` is what a host app writes; this is what a run carries. The
/// separation exists because a heterogeneous list of tools cannot be held as
/// `[any AgentTool]` and still be *called* — the associated types are gone at
/// that point — so erasure has to happen where the types are still known.
///
/// Construct one directly when the arguments are better handled as raw JSON
/// than as a Swift type.
public struct AgentFunction: Sendable {
    /// Identifier the model calls. Unique within one run.
    public let name: String
    /// What the function does, in the model's terms.
    public let description: String
    /// Schema for the argument object. `.object([:])` for a function that takes
    /// none.
    public let parameters: JSONSchema
    /// Runs the call: raw argument JSON in, the text handed back to the model
    /// out.
    ///
    /// Throwing is an ordinary outcome rather than a protocol failure. The
    /// error's description is returned to the agent as a failed call, so it can
    /// retry with different arguments or explain the problem, instead of the
    /// whole run collapsing.
    public let handler: @Sendable (Data) async throws -> String

    /// A function that takes and returns raw JSON.
    public init(
        name: String,
        description: String,
        parameters: JSONSchema = .object([:]),
        handler: @escaping @Sendable (Data) async throws -> String
    ) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.handler = handler
    }

    /// A function whose arguments decode into a Swift type.
    ///
    /// `Output` is returned verbatim when it is a `String` and JSON-encoded
    /// otherwise, so a record reaches the model as a record rather than as a
    /// Swift-flavoured description of one.
    public init<Input: Decodable & Sendable, Output: Encodable & Sendable>(
        name: String,
        description: String,
        parameters: JSONSchema,
        decoding inputType: Input.Type,
        handler: @escaping @Sendable (Input) async throws -> Output
    ) {
        self.init(name: name, description: description, parameters: parameters) { data in
            let input: Input
            do {
                input = try JSONDecoder().decode(Input.self, from: data)
            } catch {
                throw AgentToolError.undecodableArguments(
                    tool: name,
                    reason: error.localizedDescription
                )
            }
            return try Self.encode(try await handler(input))
        }
    }

    /// Erases a typed tool.
    public init<Tool: AgentTool>(_ tool: Tool) {
        self.init(
            name: tool.name,
            description: tool.description,
            parameters: tool.argumentSchema,
            decoding: Tool.Arguments.self
        ) { arguments in
            try await tool.call(arguments: arguments)
        }
    }

    static func encode(_ value: some Encodable) throws -> String {
        if let text = value as? String { return text }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}

extension AgentFunction {
    /// Names are constrained because they are matched literally out of a JSON
    /// reply, and a name with a quote or a newline in it turns a parse into a
    /// guess.
    static let allowedNameCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"
    )

    /// Checks a tool set before a run starts.
    ///
    /// Up front on purpose: a tool the model cannot name is a tool that never
    /// gets called and never explains why, which is among the least debuggable
    /// failures this package can produce.
    static func validate(_ functions: [AgentFunction]) throws {
        var seen = Set<String>()
        for function in functions {
            guard !function.name.isEmpty else {
                throw AgenticCLIError.invalidTool(name: function.name, reason: "the name is empty")
            }
            guard function.name.unicodeScalars.allSatisfy(allowedNameCharacters.contains) else {
                throw AgenticCLIError.invalidTool(
                    name: function.name,
                    reason: "names may use only letters, digits, '_' and '-'"
                )
            }
            guard function.name.count <= 64 else {
                throw AgenticCLIError.invalidTool(
                    name: function.name,
                    reason: "names must be at most 64 characters"
                )
            }
            guard !function.description.isEmpty else {
                throw AgenticCLIError.invalidTool(
                    name: function.name,
                    reason: "a tool with no description is one the model cannot know when to call"
                )
            }
            guard seen.insert(function.name).inserted else {
                throw AgenticCLIError.invalidTool(name: function.name, reason: "two tools share this name")
            }
        }
    }
}

/// Failures raised while dispatching a call. Reported back to the agent as a
/// failed tool result rather than thrown past it.
public enum AgentToolError: Error, LocalizedError, Sendable {
    case undecodableArguments(tool: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case let .undecodableArguments(tool, reason):
            return "Arguments for '\(tool)' did not match its schema: \(reason)"
        }
    }
}
