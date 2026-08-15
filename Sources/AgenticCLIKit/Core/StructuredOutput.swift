import Foundation

/// A Swift type an agent can be asked to produce directly.
///
/// ```swift
/// struct CommitMessage: StructuredOutput {
///     let commitSubject: String
///     let commitDescription: String
///
///     static let outputSchema = JSONSchema.object([
///         "commitSubject": .string("Imperative mood, at most 50 characters"),
///         "commitDescription": .string("Body explaining why the change was made"),
///     ])
/// }
///
/// let response = try await kit.run(
///     "Summarise the uncommitted changes as a commit message",
///     returning: CommitMessage.self,
///     using: .claudeCode,
///     configuration: .readOnly(in: repositoryURL)
/// )
///
/// print(response.value.commitSubject)
/// print(response.usage?.costUSD)      // the plain response is still right there
/// ```
public protocol StructuredOutput: Decodable, Sendable {
    /// The shape the CLI is told to enforce.
    static var outputSchema: JSONSchema { get }
}

/// A decoded value plus the run that produced it.
///
/// ``AgentResponse`` itself is deliberately *not* generic. It is the payload of
/// ``AgentEvent/finished(_:)``, and making it generic would push a type
/// parameter through `AgentEvent`, `AgentEventStream`, and every adapter — for
/// a value that only exists on one of the two code paths. Wrapping instead
/// keeps the streaming API untouched.
///
/// Members of the underlying response are reachable directly
/// (`response.session`, `response.usage`, `response.text`), so the wrapper adds
/// `value` without taking anything away.
@dynamicMemberLookup
public struct StructuredResponse<Value: Sendable>: Sendable {
    /// The decoded value.
    public let value: Value
    /// The full run: text, session, usage, cost, raw output.
    public let response: AgentResponse

    public init(value: Value, response: AgentResponse) {
        self.value = value
        self.response = response
    }

    public subscript<T>(dynamicMember keyPath: KeyPath<AgentResponse, T>) -> T {
        response[keyPath: keyPath]
    }
}

// MARK: - Extracting JSON from an agent's answer

extension AgentResponse {
    /// Decodes the run's structured output.
    ///
    /// Prefers the field the CLI populated after validating against the schema,
    /// and falls back to finding JSON in the message text. The order matters:
    /// `agy` returns prose *and* JSON in its text but a clean object in
    /// `structured_output`, so text-first parsing would hand back the prose.
    public func decode<Value: Decodable>(
        as type: Value.Type,
        using decoder: JSONDecoder = JSONDecoder()
    ) throws -> Value {
        if let structuredOutput {
            do {
                return try decoder.decode(type, from: structuredOutput)
            } catch {
                throw AgenticCLIError.structuredOutputFailed(
                    reason: "The CLI's structured output did not match \(type): \(error)",
                    text: String(decoding: structuredOutput, as: UTF8.self)
                )
            }
        }

        guard let json = StructuredOutputExtraction.firstJSONValue(in: text) else {
            throw AgenticCLIError.structuredOutputFailed(
                reason: "No JSON object found in the agent's reply",
                text: text
            )
        }

        do {
            return try decoder.decode(type, from: Data(json.utf8))
        } catch {
            throw AgenticCLIError.structuredOutputFailed(
                reason: "Could not decode the agent's reply as \(type): \(error)",
                text: json
            )
        }
    }
}

/// Finds a JSON value inside text that may also contain prose or code fences.
enum StructuredOutputExtraction {
    /// Returns the first complete JSON object or array in `text`.
    ///
    /// Handles the three shapes seen in practice: bare JSON, JSON inside a
    /// ```` ```json ```` fence, and JSON preceded or followed by commentary.
    static func firstJSONValue(in text: String) -> String? {
        if let fenced = fencedJSON(in: text), let balanced = balancedValue(in: fenced) {
            return balanced
        }
        return balancedValue(in: text)
    }

    private static func fencedJSON(in text: String) -> String? {
        guard let fenceStart = text.range(of: "```") else { return nil }
        // Skip an optional language tag on the opening fence.
        var contentStart = text.index(fenceStart.upperBound, offsetBy: 0)
        if let newline = text[contentStart...].firstIndex(of: "\n") {
            contentStart = text.index(after: newline)
        }
        guard let fenceEnd = text.range(of: "```", range: contentStart..<text.endIndex) else {
            return String(text[contentStart...])
        }
        return String(text[contentStart..<fenceEnd.lowerBound])
    }

    /// Scans for the first `{`/`[` and returns through its matching close,
    /// respecting strings and escapes so a brace inside a string cannot end it
    /// early.
    private static func balancedValue(in text: String) -> String? {
        let characters = Array(text)
        guard let start = characters.firstIndex(where: { $0 == "{" || $0 == "[" }) else { return nil }

        let opening = characters[start]
        let closing: Character = opening == "{" ? "}" : "]"
        var depth = 0
        var insideString = false
        var isEscaped = false

        for index in start..<characters.count {
            let character = characters[index]

            if isEscaped {
                isEscaped = false
                continue
            }
            if character == "\\", insideString {
                isEscaped = true
                continue
            }
            if character == "\"" {
                insideString.toggle()
                continue
            }
            guard !insideString else { continue }

            if character == opening {
                depth += 1
            } else if character == closing {
                depth -= 1
                if depth == 0 {
                    return String(characters[start...index])
                }
            }
        }
        return nil
    }
}

// MARK: - Typed runs

extension AgenticCLI {
    /// Runs a prompt and decodes the reply into `Output`.
    ///
    /// Adapters with ``CLICapabilities/nativeOutputSchema`` hand the schema to
    /// the CLI, which constrains the model's final message. Adapters without it
    /// throw rather than silently degrading to "please reply with JSON and hope"
    /// — a run that costs the user tokens should not have a hidden failure mode.
    public func run<Output: StructuredOutput>(
        _ prompt: String,
        returning type: Output.Type,
        configuration: RunConfiguration
    ) async throws -> StructuredResponse<Output> {
        var configuration = configuration
        configuration.outputSchema = Output.outputSchema
        try requireCapabilities(.nativeOutputSchema)

        let response = try await run(prompt, configuration: configuration)
        return StructuredResponse(value: try response.decode(as: type), response: response)
    }

    /// Resumes a session and decodes the reply into `Output`.
    public func resume<Output: StructuredOutput>(
        _ session: SessionReference,
        with prompt: String,
        returning type: Output.Type,
        configuration: RunConfiguration
    ) async throws -> StructuredResponse<Output> {
        var configuration = configuration
        configuration.outputSchema = Output.outputSchema
        try requireCapabilities([.nativeOutputSchema, .sessions])

        let response = try await resume(session, with: prompt, configuration: configuration)
        return StructuredResponse(value: try response.decode(as: type), response: response)
    }
}

extension AgenticCLIKit {
    /// Runs a prompt through a registered CLI and decodes the reply.
    public func run<Output: StructuredOutput>(
        _ prompt: String,
        returning type: Output.Type,
        using identifier: CLIIdentifier,
        configuration: RunConfiguration
    ) async throws -> StructuredResponse<Output> {
        let agent = try agent(for: identifier)
        try await agent.verifyReady()
        let structured = try await agent.run(prompt, returning: type, configuration: configuration)
        _ = try? await sessionStore.record(structured.response)
        return structured
    }

    /// Resumes a session and decodes the reply.
    public func resume<Output: StructuredOutput>(
        _ session: SessionReference,
        with prompt: String,
        returning type: Output.Type,
        configuration: RunConfiguration
    ) async throws -> StructuredResponse<Output> {
        let agent = try agent(for: session.cli)
        try await agent.verifyReady()
        let structured = try await agent.resume(
            session,
            with: prompt,
            returning: type,
            configuration: configuration
        )
        _ = try? await sessionStore.record(structured.response)
        return structured
    }

    /// The registered adapters that can enforce a schema.
    public var structuredOutputAgents: [any AgenticCLI] {
        agents(supporting: [.prompting, .nativeOutputSchema])
    }
}
