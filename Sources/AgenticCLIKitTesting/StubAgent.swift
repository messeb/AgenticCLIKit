import AgenticCLIKit
import Foundation

extension CLIIdentifier {
    /// Identity used by ``StubAgent``. Never matches a real CLI.
    public static let stub = CLIIdentifier("stub")
}

/// A minimal ``AgenticCLI`` with capabilities you choose.
///
/// Exists so that tests for graceful degradation — what happens when a CLI
/// cannot stream, cannot resume, or cannot report models — do not have to borrow
/// a shipped adapter that merely happens to lack the feature today. Pinning
/// those tests to a real adapter makes them fail for the wrong reason the moment
/// that adapter gains the capability.
///
/// ```swift
/// let limited = StubAgent(capabilities: [])          // refuses everything
/// let streaming = StubAgent(capabilities: .conversational, events: [.assistantMessage("hi")])
/// ```
public struct StubAgent: AgenticCLI {
    public static let identifier = CLIIdentifier.stub

    public let capabilities: CLICapabilities
    public let displayName: String
    public let executableName: String
    public let installHint: String
    public let loginCommand: String
    public let minimumSupportedVersion: SemanticVersion
    /// Reported by ``installation()``. `nil` means "not installed".
    public let installedVersion: SemanticVersion?
    public let authentication: AuthenticationStatus
    public let models: [AgentModel]
    /// Yielded in order by both stream methods.
    public let events: [AgentEvent]

    public init(
        capabilities: CLICapabilities = [],
        displayName: String = "Stub",
        executableName: String = "stub",
        installHint: String = "Nothing to install; this CLI is a test double",
        loginCommand: String = "stub login",
        minimumSupportedVersion: SemanticVersion = SemanticVersion(1, 0, 0),
        installedVersion: SemanticVersion? = SemanticVersion(1, 0, 0),
        authentication: AuthenticationStatus = .authenticated(AuthenticatedAccount(method: .keychain)),
        models: [AgentModel] = [],
        events: [AgentEvent] = []
    ) {
        self.capabilities = capabilities
        self.displayName = displayName
        self.executableName = executableName
        self.installHint = installHint
        self.loginCommand = loginCommand
        self.minimumSupportedVersion = minimumSupportedVersion
        self.installedVersion = installedVersion
        self.authentication = authentication
        self.models = models
        self.events = events
    }

    public func installation() async -> Installation {
        guard let installedVersion else {
            return .missing(
                cli: Self.identifier,
                minimumSupportedVersion: minimumSupportedVersion,
                installHint: installHint
            )
        }
        return Installation(
            cli: Self.identifier,
            executableURL: URL(fileURLWithPath: "/usr/local/bin/\(executableName)"),
            version: installedVersion,
            minimumSupportedVersion: minimumSupportedVersion,
            installHint: installHint
        )
    }

    public func authenticationStatus() async -> AuthenticationStatus { authentication }

    public func availableModels() async throws -> [AgentModel] {
        guard capabilities.contains(.modelDiscovery) else {
            throw AgenticCLIError.unsupportedCapability(Self.identifier, .modelDiscovery)
        }
        return models
    }

    public func stream(_ prompt: String, configuration: RunConfiguration) -> AgentEventStream {
        makeStream(session: nil)
    }

    public func stream(
        resuming session: SessionReference,
        prompt: String,
        configuration: RunConfiguration
    ) -> AgentEventStream {
        makeStream(session: session)
    }

    private func makeStream(session: SessionReference?) -> AgentEventStream {
        AgentEventStream { continuation in
            guard capabilities.contains(.prompting) else {
                continuation.finish(
                    throwing: AgenticCLIError.unsupportedCapability(Self.identifier, .prompting)
                )
                return
            }
            if session != nil, !capabilities.contains(.sessions) {
                continuation.finish(
                    throwing: AgenticCLIError.unsupportedCapability(Self.identifier, .sessions)
                )
                return
            }
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}
