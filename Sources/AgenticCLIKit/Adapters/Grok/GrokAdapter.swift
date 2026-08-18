import Foundation

extension Grok {
    /// Drives xAI's Grok Build CLI in non-interactive headless mode.
    public struct Adapter: ProcessBackedCLI {
        public static let identifier = CLIIdentifier.grok
        public let runner: any ProcessRunner
        public let locator: any ExecutableLocating

        public init(runner: (any ProcessRunner)? = nil, locator: any ExecutableLocating = LoginShellExecutableLocator()) {
            self.runner = runner ?? SubprocessRunner(cli: .grok)
            self.locator = locator
        }

        public var displayName: String { "Grok Build" }
        public var executableName: String { "grok" }
        public var installHint: String { "curl -fsSL https://x.ai/cli/install.sh | bash" }
        public var loginCommand: String { "grok login" }
        public var minimumSupportedVersion: SemanticVersion { SemanticVersion(1, 0, 0) }
        public var capabilities: CLICapabilities {
            [.prompting, .sessions, .streaming, .structuredOutput, .modelSelection,
             .turnLimits, .usageReporting, .toolAllowlist, .resumeAcrossDirectories,
             .systemPromptCustomization, .nativeOutputSchema, .modelDiscovery, .experimental]
        }
        public var environmentPolicy: EnvironmentPolicy {
            EnvironmentPolicy.base.inheriting(["XAI_API_KEY", "GROK_HOME", "GROK_SANDBOX"])
        }

        public func authenticationStatus() async -> AuthenticationStatus {
            guard let result = await probe(["--no-auto-update", "models"]) else {
                return .probeFailed(reason: "Could not run `grok models`")
            }
            let output = (result.standardOutputText + "\n" + result.standardErrorText).lowercased()
            if output.contains("not authenticated") || output.contains("not logged in") || output.contains("grok login") {
                return .requiresLogin(loginCommand: loginCommand)
            }
            guard result.exit.isSuccess else { return .requiresLogin(loginCommand: loginCommand) }
            return .authenticated(AuthenticatedAccount(method: .keychain))
        }

        public func availableModels() async throws -> [AgentModel] {
            guard let result = await probe(["--no-auto-update", "models"]) else {
                throw AgenticCLIError.notInstalled(Self.identifier, installHint: installHint)
            }
            guard result.exit.isSuccess else {
                throw AgenticCLIError.processFailed(.grok, exitCode: result.exit.code, standardError: result.standardErrorText)
            }
            let models = Self.parseModels(result.standardOutputText)
            guard !models.isEmpty else {
                throw AgenticCLIError.malformedOutput(reason: "`grok models` produced no recognisable entries", raw: result.standardOutput)
            }
            return models
        }

        static func parseModels(_ output: String) -> [AgentModel] {
            output.split(separator: "\n").compactMap { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("*") || trimmed.hasPrefix("-") else { return nil }
                let value = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
                let id = value.replacing(" (default)", with: "")
                guard !id.isEmpty, !id.contains(" ") else { return nil }
                return AgentModel(id: id, isDefault: value.hasSuffix(" (default)"), origin: .catalog)
            }
        }

        public func stream(_ prompt: String, configuration: RunConfiguration) -> AgentEventStream {
            makeStream(prompt: prompt, session: nil, configuration: configuration)
        }

        public func stream(resuming session: SessionReference, prompt: String, configuration: RunConfiguration) -> AgentEventStream {
            makeStream(prompt: prompt, session: session, configuration: configuration)
        }

        private func makeStream(prompt: String, session: SessionReference?, configuration: RunConfiguration) -> AgentEventStream {
            AgentEventStream { continuation in
                let task = Task {
                    do {
                        if let session, session.cli != Self.identifier { throw AgenticCLIError.sessionNotFound(session) }
                        let prepared = try await prepareRun(prompt: prompt, configuration: configuration)
                        defer { prepared.workspace?.destroy() }
                        let arguments = try makeArguments(prompt: prepared.prompt, session: session, configuration: configuration)
                        let invocation = try await makeInvocation(arguments: arguments, configuration: configuration)
                        let translator = Translator(workingDirectory: configuration.workingDirectory, resumedSession: session)
                        for try await event in streamEvents(invocation: invocation, translator: translator) { continuation.yield(event) }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }

        func makeArguments(prompt: String, session: SessionReference?, configuration: RunConfiguration) throws -> [String] {
            if !configuration.persistsSession {
                throw AgenticCLIError.unsupportedCapability(Self.identifier, .ephemeralRuns)
            }
            if !configuration.additionalDirectories.isEmpty {
                throw AgenticCLIError.unsupportedCapability(Self.identifier, .additionalDirectories)
            }
            let outputFormat = configuration.outputSchema == nil ? "streaming-json" : "json"
            var arguments = ["--no-auto-update", "--single", prompt, "--output-format", outputFormat]
            arguments += try permissionArguments(for: configuration.permissions)
            if let session { arguments += ["--resume", session.sessionID] }
            if let model = configuration.model { arguments += ["--model", model] }
            if let turns = configuration.maximumTurns { arguments += ["--max-turns", String(turns)] }
            if let rules = configuration.systemPromptAppendix { arguments += ["--rules", rules] }
            if let schema = configuration.outputSchema { arguments += ["--json-schema", try schema.jsonString()] }
            return arguments
        }

        func permissionArguments(for policy: PermissionPolicy) throws -> [String] {
            switch policy {
            case .planOnly: return ["--permission-mode", "plan"]
            case .readOnly: return ["--sandbox", "read-only", "--tools", "Read,Grep,WebFetch,WebSearch"]
            case let .allowingTools(allowed, denied):
                guard !allowed.isEmpty || !denied.isEmpty else {
                    throw AgenticCLIError.unsupportedPermissionPolicy(Self.identifier, policy, reason: "an empty allowlist has no safe Grok CLI representation")
                }
                var arguments: [String] = []
                if !allowed.isEmpty { arguments += ["--tools", allowed.joined(separator: ",")] }
                for rule in denied { arguments += ["--deny", rule] }
                return arguments
            case .acceptingEdits: return ["--permission-mode", "acceptEdits", "--sandbox", "workspace"]
            case .unsafeBypassAll: return ["--always-approve"]
            }
        }
    }
}
