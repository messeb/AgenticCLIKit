import Foundation

/// One embeddable command-line agent.
///
/// Adding support for a new CLI means conforming to this protocol — nothing in
/// the core changes. Conformers declare what they can do via ``capabilities``
/// and throw ``AgenticCLIError/unsupportedCapability(_:_:)`` for the rest, so
/// call sites degrade predictably instead of guessing.
///
/// Only two members produce work: ``stream(_:configuration:)`` and
/// ``stream(resuming:prompt:configuration:)``. The buffered `run`/`resume`
/// methods are derived from them by default, which is deliberate — a buffered
/// path that parses output separately from the streaming path drifts, and then
/// the two disagree about session IDs and usage.
public protocol AgenticCLI: Sendable {
    /// Stable identity of the CLI this adapter drives.
    static var identifier: CLIIdentifier { get }
    /// Human-facing name, for pickers and status screens.
    var displayName: String { get }
    /// Executable to look for on `PATH`, e.g. `"claude"`.
    var executableName: String { get }
    /// How to install it, shown when discovery fails.
    var installHint: String { get }
    /// The command that starts the CLI's own login flow.
    var loginCommand: String { get }
    var capabilities: CLICapabilities { get }
    /// Oldest CLI release this adapter's flag mapping is verified against.
    var minimumSupportedVersion: SemanticVersion { get }

    /// Locates the binary and reads its version. Never prompts, never logs in.
    func installation() async -> Installation

    /// Non-interactive, side-effect-free credential probe under a hard timeout.
    /// Never opens a browser.
    func authenticationStatus() async -> AuthenticationStatus

    /// Starts a new conversation.
    func stream(_ prompt: String, configuration: RunConfiguration) -> AgentEventStream

    /// Continues an existing conversation, possibly from a later process run.
    func stream(
        resuming session: SessionReference,
        prompt: String,
        configuration: RunConfiguration
    ) -> AgentEventStream
}

extension AgenticCLI {
    /// Instance-level access to ``identifier``, so call sites do not need the
    /// concrete type.
    public var identifier: CLIIdentifier { Self.identifier }

    /// Runs a prompt to completion.
    public func run(_ prompt: String, configuration: RunConfiguration) async throws -> AgentResponse {
        try await stream(prompt, configuration: configuration).collected()
    }

    /// Resumes a session and runs a prompt to completion.
    public func resume(
        _ session: SessionReference,
        with prompt: String,
        configuration: RunConfiguration
    ) async throws -> AgentResponse {
        try await stream(resuming: session, prompt: prompt, configuration: configuration).collected()
    }

    /// Installed, new enough, and authenticated — everything needed before a run
    /// can be expected to succeed.
    ///
    /// Discovery and the auth probe run concurrently. They are logically
    /// sequential — there is no point asking an uninstalled CLI who is signed in
    /// — but running them in series doubles the latency of a cold launch screen,
    /// and a probe against a missing executable fails immediately anyway.
    public func readiness() async -> Readiness {
        async let installationProbe = installation()
        async let authenticationProbe = authenticationStatus()

        let resolvedInstallation = await installationProbe

        guard resolvedInstallation.isInstalled else {
            _ = await authenticationProbe
            return Readiness(
                installation: resolvedInstallation,
                authentication: .probeFailed(reason: "Not installed"),
                blocker: .notInstalled(identifier, installHint: installHint)
            )
        }
        guard resolvedInstallation.meetsMinimumVersion else {
            _ = await authenticationProbe
            return Readiness(
                installation: resolvedInstallation,
                authentication: .probeFailed(reason: "Version unsupported"),
                blocker: .unsupportedVersion(
                    identifier,
                    found: resolvedInstallation.version,
                    minimum: minimumSupportedVersion
                )
            )
        }

        let authentication = await authenticationProbe
        let blocker: AgenticCLIError? = authentication.isBlocked
            ? .notAuthenticated(identifier, loginCommand: authentication.loginCommand ?? loginCommand)
            : nil

        return Readiness(
            installation: resolvedInstallation,
            authentication: authentication,
            blocker: blocker
        )
    }

    /// Throws the first thing standing between the caller and a successful run.
    public func verifyReady() async throws {
        if let blocker = await readiness().blocker { throw blocker }
    }

    /// Guard for adapters: throws unless every capability in `required` is present.
    func requireCapabilities(_ required: CLICapabilities) throws {
        let missing = required.subtracting(capabilities)
        guard missing.isEmpty else {
            throw AgenticCLIError.unsupportedCapability(identifier, missing)
        }
    }
}

/// The outcome of a readiness check: what was found, and what blocks a run.
public struct Readiness: Sendable {
    public let installation: Installation
    public let authentication: AuthenticationStatus
    /// The first blocking problem, or `nil` when the CLI is ready.
    public let blocker: AgenticCLIError?

    public init(installation: Installation, authentication: AuthenticationStatus, blocker: AgenticCLIError?) {
        self.installation = installation
        self.authentication = authentication
        self.blocker = blocker
    }

    public var isReady: Bool { blocker == nil }
}
