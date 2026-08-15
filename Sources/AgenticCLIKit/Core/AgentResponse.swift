import Foundation

/// The result of a completed run.
public struct AgentResponse: Sendable {
    /// The agent's final message, with no wrapper formatting.
    public let text: String
    /// Session handle when the CLI created a resumable conversation.
    public let session: SessionReference?
    public let usage: UsageInfo?
    public let exitCode: Int32
    /// Whether the CLI itself flagged the turn as an error, which is not always
    /// the same as a non-zero exit code.
    public let isError: Bool
    /// Reason the turn stopped, verbatim from the CLI (`"end_turn"`,
    /// `"error_max_turns"`, …), when it reports one.
    public let stopReason: String?
    /// The JSON the CLI produced under an output schema, when it reports one
    /// separately from the message text. Decode it with ``decode(as:using:)``
    /// rather than reading it directly.
    public let structuredOutput: Data?
    /// Raw stdout — the JSON or JSONL the CLI produced. The escape hatch for
    /// anything the kit does not model.
    public let rawOutput: Data?
    /// Captured stderr, trimmed. Useful in bug reports; may contain paths.
    public let standardError: String
    /// Wall-clock time measured by the kit, including process startup.
    public let duration: Duration

    public init(
        text: String,
        session: SessionReference? = nil,
        usage: UsageInfo? = nil,
        exitCode: Int32,
        isError: Bool = false,
        stopReason: String? = nil,
        structuredOutput: Data? = nil,
        rawOutput: Data? = nil,
        standardError: String = "",
        duration: Duration = .zero
    ) {
        self.text = text
        self.session = session
        self.usage = usage
        self.exitCode = exitCode
        self.isError = isError
        self.stopReason = stopReason
        self.structuredOutput = structuredOutput
        self.rawOutput = rawOutput
        self.standardError = standardError
        self.duration = duration
    }

    /// Decodes ``rawOutput`` as a specific type, for callers that want the
    /// vendor payload rather than the normalised view.
    public func decodeRawOutput<T: Decodable>(as type: T.Type, using decoder: JSONDecoder = JSONDecoder()) throws -> T {
        guard let rawOutput else {
            throw AgenticCLIError.malformedOutput(reason: "No raw output captured", raw: nil)
        }
        return try decoder.decode(type, from: rawOutput)
    }
}
