import Foundation

/// Namespace for the GitHub CLI (`gh`) adapter.
///
/// Verified against `gh` 2.97.0.
public enum GitHub {}

extension GitHub {
    /// Drives the GitHub CLI.
    ///
    /// `gh` is not an agent: it takes commands, not prompts, and it has no
    /// conversations to resume. It is in the kit on purpose. An abstraction
    /// with only well-behaved members is untested; keeping a deliberately
    /// capability-poor adapter in the core forces every call site to respect
    /// ``CLICapabilities`` instead of assuming every CLI is Claude-shaped.
    ///
    /// ``stream(_:configuration:)`` throws
    /// ``AgenticCLIError/unsupportedCapability(_:_:)``. Use
    /// ``execute(_:configuration:)`` or ``decodeJSON(_:as:configuration:decoder:)``.
    public struct Adapter: ProcessBackedCLI {
        public static let identifier = CLIIdentifier.github

        public let runner: any ProcessRunner
        public let locator: any ExecutableLocating

        public init(
            runner: (any ProcessRunner)? = nil,
            locator: any ExecutableLocating = LoginShellExecutableLocator()
        ) {
            self.runner = runner ?? SubprocessRunner(cli: .github)
            self.locator = locator
        }

        public var displayName: String { "GitHub CLI" }
        public var executableName: String { "gh" }
        public var installHint: String { "brew install gh" }
        public var loginCommand: String { "gh auth login" }
        public var minimumSupportedVersion: SemanticVersion { SemanticVersion(2, 0, 0) }

        /// No prompting, no sessions, no streaming — but it does speak JSON.
        public var capabilities: CLICapabilities { [.structuredOutput] }

        public var environmentPolicy: EnvironmentPolicy {
            EnvironmentPolicy.base.inheriting(Self.credentialVariables + [
                "GH_HOST", "GH_CONFIG_DIR", "GH_REPO",
            ])
        }

        static let credentialVariables = ["GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN"]

        // MARK: - Authentication

        public func authenticationStatus() async -> AuthenticationStatus {
            // `gh auth status` writes its report to stderr and signals state
            // through the exit code.
            guard let result = await probe(["auth", "status"]) else {
                return .probeFailed(reason: "Could not run `gh auth status`")
            }

            let output = result.standardErrorText.isEmpty
                ? result.standardOutputText
                : result.standardErrorText
            let environmentKey = environmentPolicy
                .presentKeys(among: Self.credentialVariables, in: hostEnvironment)
                .first

            guard result.exit.isSuccess else {
                if let environmentKey {
                    return .authenticated(AuthenticatedAccount(
                        method: .environmentKey,
                        environmentVariable: environmentKey
                    ))
                }
                return .requiresLogin(loginCommand: loginCommand)
            }

            return .authenticated(AuthenticatedAccount(
                identifier: Self.parseAccount(from: output),
                method: environmentKey != nil ? .environmentKey : .oauth,
                organization: Self.parseHost(from: output),
                environmentVariable: environmentKey
            ))
        }

        /// Extracts `messeb` from "✓ Logged in to github.com account messeb (keyring)".
        static func parseAccount(from output: String) -> String? {
            for line in output.split(separator: "\n") {
                guard let range = line.range(of: "account ") else { continue }
                let remainder = line[range.upperBound...]
                let account = remainder.prefix { !$0.isWhitespace }
                if !account.isEmpty { return String(account) }
            }
            return nil
        }

        /// The first host heading in the status report, e.g. `github.com`.
        static func parseHost(from output: String) -> String? {
            output
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { $0.contains(".") && !$0.contains(" ") && !$0.hasPrefix("-") }
        }

        // MARK: - AgenticCLI conformance (deliberately degraded)

        public func stream(_ prompt: String, configuration: RunConfiguration) -> AgentEventStream {
            .failing(with: AgenticCLIError.unsupportedCapability(Self.identifier, .prompting))
        }

        public func stream(
            resuming session: SessionReference,
            prompt: String,
            configuration: RunConfiguration
        ) -> AgentEventStream {
            .failing(with: AgenticCLIError.unsupportedCapability(Self.identifier, .sessions))
        }

        // MARK: - The API `gh` actually has

        /// Runs `gh` with explicit arguments.
        ///
        /// - Parameters:
        ///   - arguments: everything after the executable, e.g. `["pr", "create", "--fill"]`.
        ///   - configuration: working directory, environment, and timeout. The
        ///     permission policy is unused — `gh` has no agent to constrain.
        public func execute(
            _ arguments: [String],
            configuration: RunConfiguration
        ) async throws -> AgentResponse {
            let clock = ContinuousClock()
            let started = clock.now
            let invocation = try await makeInvocation(arguments: arguments, configuration: configuration)
            Log.info(.execution, "gh: \(arguments.first ?? "?")")

            let result = try await runner.run(invocation)
            let standardError = result.standardErrorText

            guard result.exit.isSuccess else {
                throw Self.mapFailure(exit: result.exit, standardError: standardError)
            }

            return AgentResponse(
                text: result.standardOutputText.trimmingCharacters(in: .whitespacesAndNewlines),
                session: nil,
                usage: nil,
                exitCode: result.exit.code,
                isError: false,
                stopReason: nil,
                rawOutput: result.standardOutput,
                standardError: standardError,
                duration: clock.now - started
            )
        }

        /// Runs `gh` and decodes its JSON output.
        ///
        /// Remember that most `gh` commands need an explicit field list:
        /// `["pr", "list", "--json", "number,title"]`.
        public func decodeJSON<T: Decodable>(
            _ arguments: [String],
            as type: T.Type,
            configuration: RunConfiguration,
            decoder: JSONDecoder = JSONDecoder()
        ) async throws -> T {
            let response = try await execute(arguments, configuration: configuration)
            guard let rawOutput = response.rawOutput, !rawOutput.isEmpty else {
                throw AgenticCLIError.malformedOutput(reason: "gh produced no JSON output", raw: nil)
            }
            do {
                return try decoder.decode(type, from: rawOutput)
            } catch {
                throw AgenticCLIError.malformedOutput(
                    reason: "Could not decode gh output as \(type): \(error)",
                    raw: rawOutput
                )
            }
        }

        static func mapFailure(exit: ProcessExit, standardError: String) -> AgenticCLIError {
            let message = standardError.lowercased()

            if message.contains("not logged into")
                || message.contains("authentication required")
                || message.contains("gh auth login")
                || message.contains("bad credentials") {
                return .notAuthenticated(.github, loginCommand: "gh auth login")
            }
            if message.contains("unknown flag") || message.contains("unknown command") {
                return .unsupportedByVersion(
                    .github,
                    feature: standardError.trimmingCharacters(in: .whitespacesAndNewlines),
                    found: nil
                )
            }
            return .processFailed(.github, exitCode: exit.code, standardError: standardError)
        }
    }
}
