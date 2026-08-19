import AgenticCLIKit
import Foundation

extension CLIIdentifier {
    /// Identity used by ``ScriptedAgent``. Never matches a real CLI.
    public static let scripted = CLIIdentifier("scripted")
}

/// An ``AgenticCLI`` that answers a scripted reply per invocation, and records
/// what it was asked.
///
/// ``StubAgent`` replays one fixed event list forever, which is enough for
/// capability tests but not for anything multi-turn: a tool-calling exchange is
/// several invocations, and each one has to answer differently for the loop to
/// advance. This double gives a reply per turn and keeps the prompts, so a test
/// can assert on what the agent was told between them — that a tool result was
/// actually fed back, and in what shape.
///
/// ```swift
/// let agent = ScriptedAgent(replies: [
///     .init(text: #"{"action":"call","tool":"lookup","arguments":"{}","text":""}"#),
///     .init(text: #"{"action":"final","tool":"","arguments":"","text":"42"}"#),
/// ])
/// ```
public final class ScriptedAgent: AgenticCLI, @unchecked Sendable {
    public static let identifier = CLIIdentifier.scripted

    /// One turn's answer.
    public struct Reply: Sendable {
        /// What the CLI prints as its final message.
        public var text: String
        /// What it reports separately under an output schema, when it does.
        public var structuredOutput: Data?
        public var usage: UsageInfo?
        /// Thrown instead of answering, for failure paths.
        public var failure: (any Error)?

        public init(
            text: String = "",
            structuredOutput: Data? = nil,
            usage: UsageInfo? = nil,
            failure: (any Error)? = nil
        ) {
            self.text = text
            self.structuredOutput = structuredOutput
            self.usage = usage
            self.failure = failure
        }
    }

    /// One recorded invocation.
    public struct Invocation: Sendable {
        public let prompt: String
        public let configuration: RunConfiguration
        /// The session being continued, or `nil` for the opening turn.
        public let session: SessionReference?
    }

    public let capabilities: CLICapabilities
    public let displayName = "Scripted"
    public let executableName = "scripted"
    public let installHint = "Nothing to install; this CLI is a test double"
    public let loginCommand = "scripted login"
    public let minimumSupportedVersion = SemanticVersion(1, 0, 0)
    /// Session ID handed out on the first turn and echoed afterwards.
    public let sessionID: String

    private let lock = NSLock()
    private var replies: [Reply]
    private var recorded: [Invocation] = []

    /// Replies are consumed in order. Running out is a test bug, and reported as
    /// one rather than silently repeating the last answer.
    public init(
        replies: [Reply],
        capabilities: CLICapabilities = [.prompting, .sessions, .structuredOutput, .nativeOutputSchema],
        sessionID: String = "scripted-session"
    ) {
        self.replies = replies
        self.capabilities = capabilities
        self.sessionID = sessionID
    }

    /// Every invocation so far, oldest first.
    public var invocations: [Invocation] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    /// The prompts the agent was given, oldest first.
    public var prompts: [String] { invocations.map(\.prompt) }

    public func installation() async -> Installation {
        Installation(
            cli: Self.identifier,
            executableURL: URL(fileURLWithPath: "/usr/local/bin/scripted"),
            version: minimumSupportedVersion,
            minimumSupportedVersion: minimumSupportedVersion,
            installHint: installHint
        )
    }

    public func authenticationStatus() async -> AuthenticationStatus {
        .authenticated(AuthenticatedAccount(method: .keychain))
    }

    public func availableModels() async throws -> [AgentModel] {
        throw AgenticCLIError.unsupportedCapability(Self.identifier, .modelDiscovery)
    }

    public func stream(_ prompt: String, configuration: RunConfiguration) -> AgentEventStream {
        makeStream(prompt: prompt, configuration: configuration, session: nil)
    }

    public func stream(
        resuming session: SessionReference,
        prompt: String,
        configuration: RunConfiguration
    ) -> AgentEventStream {
        makeStream(prompt: prompt, configuration: configuration, session: session)
    }

    private func makeStream(
        prompt: String,
        configuration: RunConfiguration,
        session: SessionReference?
    ) -> AgentEventStream {
        AgentEventStream { [self] continuation in
            if session != nil, !capabilities.contains(.sessions) {
                continuation.finish(
                    throwing: AgenticCLIError.unsupportedCapability(Self.identifier, .sessions)
                )
                return
            }

            lock.lock()
            recorded.append(Invocation(prompt: prompt, configuration: configuration, session: session))
            let reply = replies.isEmpty ? nil : replies.removeFirst()
            lock.unlock()

            guard let reply else {
                continuation.finish(throwing: AgenticCLIError.malformedOutput(
                    reason: "ScriptedAgent ran out of replies after \(invocations.count) invocation(s)",
                    raw: nil
                ))
                return
            }
            if let failure = reply.failure {
                continuation.finish(throwing: failure)
                return
            }

            let reference = session?.touched() ?? SessionReference(
                cli: Self.identifier,
                sessionID: sessionID,
                workingDirectory: configuration.workingDirectory
            )
            continuation.yield(.sessionStarted(reference))
            continuation.yield(.assistantMessage(reply.text))
            continuation.yield(.finished(AgentResponse(
                text: reply.text,
                session: reference,
                usage: reply.usage,
                exitCode: 0,
                structuredOutput: reply.structuredOutput
            )))
            continuation.finish()
        }
    }
}
