import Foundation

/// One record of a tool the agent actually ran.
public struct ToolCall: Sendable {
    public let tool: String
    /// The argument JSON the model produced.
    public let arguments: Data
    /// What was handed back to it.
    public let output: String
    /// True when the tool threw and the agent was told so.
    public let isError: Bool
    /// How long the host's own code took.
    public let duration: Duration

    /// The arguments decoded, for a caller inspecting the trace afterwards.
    public func arguments<T: Decodable>(as type: T.Type, using decoder: JSONDecoder = JSONDecoder()) throws -> T {
        try decoder.decode(type, from: arguments)
    }
}

/// The answer to one ``AgentSession/respond(to:)``, with the tool calls it took
/// to get there.
public struct AgentSessionResponse: Sendable {
    /// The agent's answer, unwrapped from the exchange format.
    public let text: String
    /// Every tool the agent ran during this turn, in order.
    public let toolCalls: [ToolCall]
    /// How many CLI round trips it cost, including the first.
    public let rounds: Int
    /// Tokens and cost across every round, where the CLI reports them.
    public let usage: UsageInfo?
    /// The last underlying response, for exit codes, raw output and stderr.
    public let response: AgentResponse
}

/// A conversation with an agent that can call the host app's tools.
///
/// The Foundation Models shape — construct with tools and instructions, then
/// ``respond(to:)`` as many times as the conversation needs — over a CLI
/// instead of an on-device model.
///
/// ```swift
/// let session = AgentSession(
///     cli: .claudeCode,
///     workingDirectory: directory,
///     tools: [WeatherTool()],
///     instructions: "Help the person with getting weather information"
/// )
///
/// let response = try await session.respond(to: "Is it hotter in Boston, Wichita, or Pittsburgh?")
/// print(response.text)
/// print(response.toolCalls.map(\.tool))  // ["getWeather", "getWeather", "getWeather"]
/// ```
///
/// One `respond(to:)` may cost several CLI invocations: the agent asks for a
/// tool, the session runs it and resumes the conversation with the result, and
/// that repeats until the agent answers. ``maximumToolRounds`` bounds it, so a
/// model that loops cannot bill forever.
///
/// The CLI must support ``CLICapabilities/sessions`` — resuming is how a result
/// gets back to the agent. Everything else degrades: a CLI with
/// ``CLICapabilities/nativeOutputSchema`` has the reply shape enforced by the
/// provider, and one without is asked in the prompt and parsed leniently.
public actor AgentSession {
    private let kit: AgenticCLIKit
    private let cli: CLIIdentifier
    private let functions: [AgentFunction]
    private let instructions: String?
    private let configuration: RunConfiguration
    /// Upper bound on tool calls per ``respond(to:)``.
    public let maximumToolRounds: Int

    /// The CLI-side conversation, once one exists. Persisted by the kit's
    /// session store like any other run, so it survives the process.
    public private(set) var session: SessionReference?

    public init(
        kit: AgenticCLIKit = AgenticCLIKit(),
        cli: CLIIdentifier,
        workingDirectory: URL,
        tools: [any AgentTool] = [],
        functions: [AgentFunction] = [],
        instructions: String? = nil,
        configuration: RunConfiguration? = nil,
        maximumToolRounds: Int = 8,
        resuming session: SessionReference? = nil
    ) {
        self.kit = kit
        self.cli = cli
        self.functions = tools.erased + functions
        self.instructions = instructions
        self.configuration = configuration
            ?? RunConfiguration(workingDirectory: workingDirectory, permissions: .readOnly)
        self.maximumToolRounds = maximumToolRounds
        self.session = session
    }

    /// Runs one exchange to completion, resolving tool calls along the way.
    public func respond(to prompt: String) async throws -> AgentSessionResponse {
        let agent = try kit.agent(for: cli)
        try AgentFunction.validate(functions)

        guard !functions.isEmpty else {
            // No tools means no exchange format is needed, and imposing one
            // would only cost a turn and a chance to get the JSON wrong.
            let response = try await continueConversation(prompt, configuration: configuration)
            return AgentSessionResponse(
                text: response.text,
                toolCalls: [],
                rounds: 1,
                usage: response.usage,
                response: response
            )
        }
        try agent.requireCapabilities(.sessions)

        var configuration = configuration
        if agent.capabilities.contains(.nativeOutputSchema) {
            configuration.outputSchema = ToolCallFormat.schema
        }

        var next = ToolCallFormat.preamble(for: functions, instructions: instructions) + "\n\nTASK\n" + prompt
        var toolCalls: [ToolCall] = []
        var usage: [UsageInfo] = []
        var rounds = 0
        var repairsLeft = 1

        while rounds < maximumToolRounds {
            rounds += 1
            let response = try await continueConversation(next, configuration: configuration)
            if let reported = response.usage { usage.append(reported) }

            let reply: ToolCallFormat.Reply
            do {
                reply = try ToolCallFormat.parse(
                    structuredOutput: response.structuredOutput,
                    text: response.text
                )
            } catch let error as AgenticCLIError {
                // One correction, then the failure stands. A model that cannot
                // produce the format twice will not produce it on the tenth try
                // either, and every attempt is billed.
                guard repairsLeft > 0, case let .toolCallProtocolViolation(reason, _) = error else {
                    throw error
                }
                repairsLeft -= 1
                next = ToolCallFormat.repairPrompt(reason: reason)
                continue
            }

            switch reply {
            case let .final(text):
                return AgentSessionResponse(
                    text: text,
                    toolCalls: toolCalls,
                    rounds: rounds,
                    usage: UsageInfo.combined(usage),
                    response: response
                )

            case let .call(tool, arguments):
                let call = await invoke(tool, arguments: arguments)
                toolCalls.append(call)
                next = ToolCallFormat.resultPrompt(
                    tool: tool,
                    output: call.output,
                    isError: call.isError
                )
            }
        }

        throw AgenticCLIError.toolCallLimitReached(cli, rounds: maximumToolRounds, calls: toolCalls.map(\.tool))
    }

    /// Starts the conversation or continues it, recording the session either way.
    private func continueConversation(
        _ prompt: String,
        configuration: RunConfiguration
    ) async throws -> AgentResponse {
        let response: AgentResponse
        if let session {
            response = try await kit.resume(session, with: prompt, configuration: configuration)
        } else {
            response = try await kit.run(prompt, using: cli, configuration: configuration)
        }
        if let started = response.session { session = started }
        return response
    }

    /// Runs one tool, turning a thrown error into a result the agent can read.
    private func invoke(_ tool: String, arguments: Data) async -> ToolCall {
        let clock = ContinuousClock()
        let started = clock.now

        guard let function = functions.first(where: { $0.name == tool }) else {
            // Naming a tool that does not exist is a mistake the agent can
            // recover from, so it is told rather than the run being failed.
            let known = functions.map(\.name).joined(separator: ", ")
            return ToolCall(
                tool: tool,
                arguments: arguments,
                output: "No such tool. Available tools: \(known)",
                isError: true,
                duration: clock.now - started
            )
        }

        do {
            let output = try await function.handler(arguments)
            Log.debug(.execution, "\(cli): tool \(tool) returned \(output.count) characters")
            return ToolCall(
                tool: tool,
                arguments: arguments,
                output: output,
                isError: false,
                duration: clock.now - started
            )
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            Log.warning(.execution, "\(cli): tool \(tool) failed — \(message)")
            return ToolCall(
                tool: tool,
                arguments: arguments,
                output: message,
                isError: true,
                duration: clock.now - started
            )
        }
    }
}

extension AgenticCLIKit {
    /// One-shot tool calling: run a prompt with tools, get the answer.
    ///
    /// Convenience over ``AgentSession``, for the case where the conversation
    /// ends with the answer. Use the session type directly to ask a follow-up.
    public func run(
        _ prompt: String,
        tools: [any AgentTool],
        using identifier: CLIIdentifier,
        configuration: RunConfiguration,
        instructions: String? = nil,
        maximumToolRounds: Int = 8
    ) async throws -> AgentSessionResponse {
        try await AgentSession(
            kit: self,
            cli: identifier,
            workingDirectory: configuration.workingDirectory,
            tools: tools,
            instructions: instructions,
            configuration: configuration,
            maximumToolRounds: maximumToolRounds
        ).respond(to: prompt)
    }
}

extension UsageInfo {
    /// Sums what the CLI reported across the rounds of one exchange.
    ///
    /// A tool-calling turn is several CLI invocations, and a caller watching
    /// spend needs the total rather than the last one's share. Fields nobody
    /// reported stay `nil`, so "not measured" never reads as zero.
    static func combined(_ reports: [UsageInfo]) -> UsageInfo? {
        guard !reports.isEmpty else { return nil }

        func sum(_ keyPath: KeyPath<UsageInfo, Int?>) -> Int? {
            let values = reports.compactMap { $0[keyPath: keyPath] }
            return values.isEmpty ? nil : values.reduce(0, +)
        }
        func sum(_ keyPath: KeyPath<UsageInfo, Double?>) -> Double? {
            let values = reports.compactMap { $0[keyPath: keyPath] }
            return values.isEmpty ? nil : values.reduce(0, +)
        }

        return UsageInfo(
            inputTokens: sum(\.inputTokens),
            outputTokens: sum(\.outputTokens),
            cachedInputTokens: sum(\.cachedInputTokens),
            cacheWriteTokens: sum(\.cacheWriteTokens),
            reasoningTokens: sum(\.reasoningTokens),
            costUSD: sum(\.costUSD),
            premiumRequests: sum(\.premiumRequests),
            aiCredits: sum(\.aiCredits),
            turns: sum(\.turns),
            model: reports.compactMap(\.model).first,
            duration: reports.compactMap(\.duration).reduce(Duration.zero, +)
        )
    }
}
