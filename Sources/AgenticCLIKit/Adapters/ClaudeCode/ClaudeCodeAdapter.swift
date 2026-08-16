import Foundation

extension ClaudeCode {
    /// Drives Anthropic's `claude` CLI.
    ///
    /// Sessions are cross-directory: a conversation started in one repository
    /// can be resumed from anywhere with `--resume <id>`.
    ///
    /// Verified against `claude` 2.1.224. Note that this build has no
    /// `--max-turns` flag, so ``CLICapabilities/turnLimits`` is absent and
    /// ``RunConfiguration/maximumTurns`` is rejected rather than ignored.
    public struct Adapter: ProcessBackedCLI {
        public static let identifier = CLIIdentifier.claudeCode

        public let runner: any ProcessRunner
        public let locator: any ExecutableLocating

        public init(
            runner: (any ProcessRunner)? = nil,
            locator: any ExecutableLocating = LoginShellExecutableLocator()
        ) {
            self.runner = runner ?? SubprocessRunner(cli: .claudeCode)
            self.locator = locator
        }

        public var displayName: String { "Claude Code" }
        public var executableName: String { "claude" }
        public var installHint: String { "npm install -g @anthropic-ai/claude-code" }
        public var loginCommand: String { "claude auth login" }
        public var minimumSupportedVersion: SemanticVersion { SemanticVersion(2, 0, 0) }

        public var capabilities: CLICapabilities {
            [
                .prompting, .sessions, .streaming, .structuredOutput,
                .modelSelection, .usageReporting, .toolAllowlist,
                .resumeAcrossDirectories, .ephemeralRuns, .additionalDirectories,
                .systemPromptCustomization, .nativeOutputSchema, .fileAttachments,
                .modelDiscovery,
            ]
        }

        public var environmentPolicy: EnvironmentPolicy {
            EnvironmentPolicy.base.inheriting(Self.credentialVariables + [
                "CLAUDE_CONFIG_DIR", "ANTHROPIC_BASE_URL", "ANTHROPIC_MODEL",
                "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX",
                "AWS_REGION", "AWS_PROFILE", "CLOUD_ML_REGION",
            ])
        }

        /// Environment variables that can authenticate `claude` without a login.
        static let credentialVariables = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN"]

        // MARK: - Authentication

        public func authenticationStatus() async -> AuthenticationStatus {
            // `claude auth status` prints JSON and exits 1 when signed out. It
            // never opens a browser, which is what makes it safe to run at launch.
            guard let result = await probe(["auth", "status"]) else {
                return .probeFailed(reason: "Could not run `claude auth status`")
            }

            let payload = try? JSONDecoder().decode(
                AuthPayload.self,
                from: Data(result.standardOutputText.utf8)
            )

            guard let payload else {
                if result.exit.isSuccess {
                    return .undetectable(reason: "Unrecognised `claude auth status` output")
                }
                return .requiresLogin(loginCommand: loginCommand)
            }

            guard payload.loggedIn else {
                return .requiresLogin(loginCommand: loginCommand)
            }

            let environmentKey = environmentPolicy
                .presentKeys(among: Self.credentialVariables, in: hostEnvironment)
                .first

            let account = AuthenticatedAccount(
                identifier: payload.email,
                // An environment key overrides stored credentials, so report the
                // source that will actually be used.
                method: environmentKey != nil ? .environmentKey : payload.method,
                organization: payload.orgName,
                plan: payload.subscriptionType,
                expiresAt: payload.expiresAt,
                environmentVariable: environmentKey
            )

            if let expiry = payload.expiresAt, expiry < Date() {
                return .expired(account, loginCommand: loginCommand)
            }
            return .authenticated(account)
        }

        // MARK: - Models

        /// The maintained ``ClaudeCode/Model`` list, merged with any aliases the
        /// installed binary documents for `--model`.
        ///
        /// The help text is worth reading even though it is thin: it comes from
        /// the binary on this machine, so a newly added alias shows up without a
        /// package update. It is additive only — `claude` has no command that
        /// enumerates models, so the maintained list stays the backbone.
        public func availableModels() async throws -> [AgentModel] {
            var models = Model.agentModels
            let known = Set(models.map(\.id))

            for alias in await documentedModelAliases() where !known.contains(alias) {
                models.append(AgentModel(id: alias, origin: .documentation))
            }
            return models
        }

        /// Values quoted in the `--model` paragraph of `claude --help`.
        func documentedModelAliases() async -> [String] {
            guard let result = await probe(["--help"]), result.exit.isSuccess else { return [] }
            return Self.parseModelAliases(fromHelp: result.standardOutputText)
        }

        /// `claude --help` wraps flag descriptions across indented continuation
        /// lines, so the paragraph has to be reassembled before the quoted
        /// example values can be pulled out of it.
        static func parseModelAliases(fromHelp help: String) -> [String] {
            let lines = help.split(separator: "\n", omittingEmptySubsequences: false)
            guard let start = lines.firstIndex(where: { $0.contains("--model <model>") }) else {
                return []
            }

            var paragraph = String(lines[start])
            for line in lines[(start + 1)...] {
                // A new flag starts at two spaces followed by a dash; anything
                // more deeply indented continues the current description.
                if line.hasPrefix("  -") || !line.hasPrefix("   ") { break }
                paragraph += " " + line.trimmingCharacters(in: .whitespaces)
            }

            // Excluding whitespace inside the quotes matters: the paragraph
            // contains the possessive in "model's full name", and a greedier
            // pattern pairs that apostrophe with the next quote and swallows the
            // example that follows it.
            let pattern = #"'([^'\s]+)'"#
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
            let range = NSRange(paragraph.startIndex..<paragraph.endIndex, in: paragraph)

            var aliases: [String] = []
            for match in regex.matches(in: paragraph, range: range) {
                guard let matched = Range(match.range(at: 1), in: paragraph) else { continue }
                let value = String(paragraph[matched])
                guard !value.isEmpty, !aliases.contains(value) else { continue }
                aliases.append(value)
            }
            return aliases
        }

        // MARK: - Running

        public func stream(_ prompt: String, configuration: RunConfiguration) -> AgentEventStream {
            makeStream(prompt: prompt, session: nil, configuration: configuration)
        }

        public func stream(
            resuming session: SessionReference,
            prompt: String,
            configuration: RunConfiguration
        ) -> AgentEventStream {
            makeStream(prompt: prompt, session: session, configuration: configuration)
        }

        private func makeStream(
            prompt: String,
            session: SessionReference?,
            configuration: RunConfiguration
        ) -> AgentEventStream {
            AgentEventStream { continuation in
                let task = Task {
                    var workspace: RunWorkspace?
                    // Cleanup runs before the stream finishes rather than in a
                    // `defer`, so the scratch directory is already gone by the
                    // time `run` returns to the caller.
                    var failure: (any Error)?

                    do {
                        if let session, session.cli != Self.identifier {
                            throw AgenticCLIError.sessionNotFound(session)
                        }

                        let prepared = try await prepareRun(prompt: prompt, configuration: configuration)
                        workspace = prepared.workspace

                        let arguments = try makeArguments(
                            prompt: prepared.prompt,
                            session: session,
                            configuration: configuration,
                            additionalDirectories: prepared.additionalDirectories
                        )
                        let translator = Translator(
                            workingDirectory: configuration.workingDirectory,
                            resumedSession: session
                        )
                        let invocation = try await makeInvocation(
                            arguments: arguments,
                            configuration: configuration
                        )
                        Log.info(.execution, "claude: \(arguments.count) args, \(Log.redacted(prompt))")
                        for try await event in streamEvents(invocation: invocation, translator: translator) {
                            continuation.yield(event)
                        }
                    } catch {
                        failure = error
                    }

                    workspace?.destroy()
                    if let failure {
                        continuation.finish(throwing: failure)
                    } else {
                        continuation.finish()
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }

        /// Builds the argument vector.
        ///
        /// `--verbose` is required alongside `--output-format stream-json`; the
        /// CLI rejects the combination without it.
        func makeArguments(
            prompt: String,
            session: SessionReference?,
            configuration: RunConfiguration,
            additionalDirectories: [URL]? = nil
        ) throws -> [String] {
            if let session {
                try validateResume(session, against: configuration)
            }
            if configuration.maximumTurns != nil {
                throw AgenticCLIError.unsupportedCapability(Self.identifier, .turnLimits)
            }

            var arguments = ["--print", prompt]
            arguments += ["--output-format", "stream-json", "--verbose", "--include-partial-messages"]
            arguments += try permissionArguments(for: configuration.permissions)

            if let session {
                arguments += ["--resume", session.sessionID]
            }
            if let model = configuration.model {
                arguments += ["--model", model]
            }
            if let appendix = configuration.systemPromptAppendix {
                arguments += ["--append-system-prompt", appendix]
            }
            if !configuration.persistsSession {
                arguments.append("--no-session-persistence")
            }
            if let schema = configuration.outputSchema {
                // Inline, unlike Codex: `claude` takes the schema as a string.
                arguments += ["--json-schema", try schema.jsonString()]
            }

            let directories = additionalDirectories ?? configuration.additionalDirectories
            if !directories.isEmpty {
                arguments.append("--add-dir")
                arguments += directories.map(\.path)
            }
            return arguments
        }

        private func validateResume(_ session: SessionReference, against configuration: RunConfiguration) throws {
            guard !capabilities.contains(.resumeAcrossDirectories) else { return }
            guard session.workingDirectory.standardizedFileURL == configuration.workingDirectory.standardizedFileURL
            else {
                throw AgenticCLIError.workingDirectoryMismatch(session, attempted: configuration.workingDirectory)
            }
        }

        func permissionArguments(for policy: PermissionPolicy) throws -> [String] {
            switch policy {
            case .planOnly:
                return ["--permission-mode", "plan"]

            case .readOnly:
                // `manual` denies anything outside the allowlist, and in print
                // mode there is no prompt to block on.
                return ["--permission-mode", "manual"]
                    + ["--allowedTools"] + readOnlyTools
                    + ["--disallowedTools"] + mutatingTools

            case let .allowingTools(allowed, denied):
                var arguments = ["--permission-mode", "manual"]
                if !allowed.isEmpty { arguments += ["--allowedTools"] + allowed }
                if !denied.isEmpty { arguments += ["--disallowedTools"] + denied }
                return arguments

            case .acceptingEdits:
                return ["--permission-mode", "acceptEdits"]

            case .unsafeBypassAll:
                return ["--dangerously-skip-permissions"]
            }
        }
    }
}
