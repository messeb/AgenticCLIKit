import Foundation

extension Codex {
    /// Drives OpenAI's `codex` CLI through `codex exec`.
    ///
    /// Two quirks of this CLI shape the adapter:
    ///
    /// - `codex exec` reads stdin when it is left open, printing
    ///   "Reading additional input from stdin…" and blocking. The kit always
    ///   closes stdin, so this cannot strand a host app.
    /// - `codex exec resume` accepts a *different, smaller* flag set than
    ///   `codex exec` — notably no `--sandbox` and no `--cd`. The sandbox policy
    ///   is therefore passed as `-c sandbox_mode=…` on the resume path.
    ///
    /// Verified against `codex-cli` 0.147.0.
    public struct Adapter: ProcessBackedCLI {
        public static let identifier = CLIIdentifier.codex

        public let runner: any ProcessRunner
        public let locator: any ExecutableLocating
        /// Codex refuses to run outside a git repository unless told otherwise.
        /// Host apps routinely point agents at plain folders, so this defaults
        /// to `true`.
        public let allowsNonGitDirectories: Bool

        public init(
            runner: (any ProcessRunner)? = nil,
            locator: any ExecutableLocating = LoginShellExecutableLocator(),
            allowsNonGitDirectories: Bool = true
        ) {
            self.runner = runner ?? SubprocessRunner(cli: .codex)
            self.locator = locator
            self.allowsNonGitDirectories = allowsNonGitDirectories
        }

        public var displayName: String { "Codex" }
        public var executableName: String { "codex" }
        public var installHint: String { "npm install -g @openai/codex" }
        public var loginCommand: String { "codex login" }
        public var minimumSupportedVersion: SemanticVersion { SemanticVersion(0, 100, 0) }

        public var capabilities: CLICapabilities {
            [
                .prompting, .sessions, .streaming, .structuredOutput,
                .modelSelection, .usageReporting, .resumeAcrossDirectories,
                .ephemeralRuns, .additionalDirectories, .nativeOutputSchema,
                .fileAttachments, .nativeImageAttachments, .modelDiscovery,
            ]
        }

        public var environmentPolicy: EnvironmentPolicy {
            EnvironmentPolicy.base.inheriting(Self.credentialVariables + [
                "CODEX_HOME", "OPENAI_BASE_URL",
            ])
        }

        static let credentialVariables = ["CODEX_API_KEY", "OPENAI_API_KEY"]

        /// Codex takes `--output-schema` as a *file path*, unlike the other two,
        /// so a schema run needs somewhere to put it.
        public var needsSchemaOnDisk: Bool { true }

        // MARK: - Authentication

        public func authenticationStatus() async -> AuthenticationStatus {
            guard let result = await probe(["login", "status"]) else {
                return .probeFailed(reason: "Could not run `codex login status`")
            }

            let output = (result.standardOutputText + result.standardErrorText)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let environmentKey = environmentPolicy
                .presentKeys(among: Self.credentialVariables, in: hostEnvironment)
                .first

            guard result.exit.isSuccess, !output.lowercased().contains("not logged in") else {
                // An API key in the environment still authenticates runs even
                // when no profile is stored.
                if let environmentKey {
                    return .authenticated(AuthenticatedAccount(
                        method: .environmentKey,
                        environmentVariable: environmentKey
                    ))
                }
                return .requiresLogin(loginCommand: loginCommand)
            }

            // Output reads "Logged in using ChatGPT" or "Logged in using an API key".
            let usesAPIKey = output.lowercased().contains("api key")
            return .authenticated(AuthenticatedAccount(
                identifier: Self.parseAccount(from: output),
                method: environmentKey != nil ? .environmentKey : (usesAPIKey ? .longLivedToken : .subscription),
                environmentVariable: environmentKey
            ))
        }

        /// Pulls an email out of the status line when one is present.
        static func parseAccount(from output: String) -> String? {
            output
                .split(whereSeparator: { $0 == " " || $0 == "\n" })
                .map(String.init)
                .first { $0.contains("@") && $0.contains(".") }
        }

        // MARK: - Models

        /// The maintained ``Codex/Model`` list, with the user's configured model
        /// marked as the default.
        ///
        /// `codex` cannot enumerate models — `codex models` exits 1 demanding a
        /// TTY — so the maintained list is the catalogue. The configured value
        /// from `config.toml` is merged in because it is the one fact about this
        /// machine that *is* knowable, and it is what a run without an explicit
        /// model will actually use.
        public func availableModels() async throws -> [AgentModel] {
            let configured = configuredModel()

            var models = Model.agentModels.map { model in
                guard let configured else { return model }
                // The user's configuration outranks the list's own default.
                return AgentModel(
                    id: model.id,
                    displayName: model.displayName,
                    summary: model.summary,
                    isDefault: model.id == configured,
                    origin: model.origin
                )
            }

            if let configured, !models.contains(where: { $0.id == configured }) {
                models.insert(
                    AgentModel(
                        id: configured,
                        summary: "Configured in config.toml",
                        isDefault: true,
                        origin: .configuration
                    ),
                    at: 0
                )
            }
            return models
        }

        /// The `model` value from `$CODEX_HOME/config.toml`, when set.
        ///
        /// Only the top-level assignment counts: `model` also appears inside
        /// profile tables, and those describe other profiles, not this run.
        public func configuredModel() -> String? {
            let home = hostEnvironment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
            let configURL = home.appendingPathComponent("config.toml")

            guard let contents = try? String(contentsOf: configURL, encoding: .utf8) else { return nil }
            return Self.parseModel(fromTOML: contents)
        }

        static func parseModel(fromTOML toml: String) -> String? {
            for rawLine in toml.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                // Stop at the first table header — everything after belongs to a
                // section, not to the top-level configuration.
                if line.hasPrefix("[") { return nil }
                guard line.hasPrefix("model"), let equals = line.firstIndex(of: "=") else { continue }

                let key = line[line.startIndex..<equals].trimmingCharacters(in: .whitespaces)
                guard key == "model" else { continue }

                let value = line[line.index(after: equals)...]
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                return value.isEmpty ? nil : value
            }
            return nil
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

                        // The schema has to survive on disk for the whole run,
                        // which is why the workspace is torn down only in the
                        // enclosing defer.
                        var schemaFileURL: URL?
                        if let schema = configuration.outputSchema {
                            guard let workspace else {
                                throw AgenticCLIError.malformedOutput(
                                    reason: "No scratch directory for the output schema",
                                    raw: nil
                                )
                            }
                            schemaFileURL = try workspace.writeSchema(schema)
                        }

                        let arguments = try makeArguments(
                            prompt: prepared.prompt,
                            session: session,
                            configuration: configuration,
                            additionalDirectories: prepared.additionalDirectories,
                            images: prepared.images.map(\.url),
                            schemaFileURL: schemaFileURL
                        )
                        let translator = Translator(
                            workingDirectory: configuration.workingDirectory,
                            resumedSession: session
                        )

                        var configuration = configuration
                        // Never let codex block on stdin.
                        configuration.standardInput = nil
                        let invocation = try await makeInvocation(
                            arguments: arguments,
                            configuration: configuration
                        )
                        Log.info(.execution, "codex: \(arguments.count) args, \(Log.redacted(prompt))")
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

        func makeArguments(
            prompt: String,
            session: SessionReference?,
            configuration: RunConfiguration,
            additionalDirectories: [URL]? = nil,
            images: [URL] = [],
            schemaFileURL: URL? = nil
        ) throws -> [String] {
            if configuration.maximumTurns != nil {
                throw AgenticCLIError.unsupportedCapability(Self.identifier, .turnLimits)
            }
            if configuration.systemPromptAppendix != nil {
                throw AgenticCLIError.unsupportedCapability(Self.identifier, .systemPromptCustomization)
            }
            let sandbox = try sandboxMode(for: configuration.permissions)

            var arguments = ["exec"]
            if session != nil { arguments.append("resume") }
            arguments.append("--json")

            if allowsNonGitDirectories { arguments.append("--skip-git-repo-check") }
            if !configuration.persistsSession { arguments.append("--ephemeral") }
            if let model = configuration.model { arguments += ["--model", model] }

            switch sandbox {
            case .some(let mode) where session == nil:
                arguments += ["--sandbox", mode.rawValue]
            case .some(let mode):
                // `codex exec resume` rejects --sandbox; the config override is
                // the only way to set the policy on this path.
                arguments += ["-c", "sandbox_mode=\"\(mode.rawValue)\""]
            case .none:
                arguments.append("--dangerously-bypass-approvals-and-sandbox")
            }

            if let schemaFileURL {
                arguments += ["--output-schema", schemaFileURL.path]
            }

            // Codex is the only one of the three with a real image flag; other
            // attachment kinds are read from disk via the prompt preamble.
            for image in images {
                arguments += ["--image", image.path]
            }

            let directories = additionalDirectories ?? configuration.additionalDirectories
            if !directories.isEmpty {
                guard session == nil else {
                    // resume has no --add-dir; widening silently would be worse.
                    throw AgenticCLIError.unsupportedCapability(Self.identifier, .additionalDirectories)
                }
                for directory in directories {
                    arguments += ["--add-dir", directory.path]
                }
            }

            // Positional arguments must come last: `codex exec resume` parses
            // <SESSION_ID> <PROMPT> only after its flags.
            if let session {
                arguments.append(session.sessionID)
            }
            arguments.append(prompt)
            return arguments
        }

        /// `nil` means "no sandbox at all" — the caller asked for
        /// ``PermissionPolicy/unsafeBypassAll``.
        func sandboxMode(for policy: PermissionPolicy) throws -> SandboxMode? {
            switch policy {
            case .planOnly, .readOnly:
                // Codex has no plan mode; a read-only sandbox is the honest
                // equivalent of "take no action".
                return .readOnly
            case .acceptingEdits:
                return .workspaceWrite
            case .allowingTools:
                // Codex sandboxes by filesystem scope, not by tool name. There
                // is no faithful mapping, so refuse rather than widen.
                throw AgenticCLIError.unsupportedPermissionPolicy(
                    Self.identifier,
                    policy,
                    reason: "codex sandboxes by filesystem scope, not by tool name"
                )
            case .unsafeBypassAll:
                return nil
            }
        }
    }
}
