import Foundation

extension Antigravity {
    /// Drives Google's `agy` CLI.
    ///
    /// Marked ``CLICapabilities/experimental``: this is the youngest CLI of the
    /// four and its print-mode semantics have changed between releases. The raw
    /// JSON remains available on ``AgentResponse/rawOutput`` for when the typed
    /// mapping falls behind.
    ///
    /// Session scope is treated as directory-bound. `agy` does not document
    /// cross-directory resume, so the adapter validates the working directory
    /// rather than assuming it works and producing a confusing failure later.
    ///
    /// Verified against `agy` 1.0.16.
    public struct Adapter: ProcessBackedCLI {
        public static let identifier = CLIIdentifier.antigravity

        public let runner: any ProcessRunner
        public let locator: any ExecutableLocating

        public init(
            runner: (any ProcessRunner)? = nil,
            locator: any ExecutableLocating = LoginShellExecutableLocator()
        ) {
            self.runner = runner ?? SubprocessRunner(cli: .antigravity)
            self.locator = locator
        }

        public var displayName: String { "Antigravity" }
        public var executableName: String { "agy" }
        public var installHint: String { "Install Antigravity from https://antigravity.google, then run `agy install`" }
        public var loginCommand: String { "agy" }
        public var minimumSupportedVersion: SemanticVersion { SemanticVersion(1, 0, 0) }
        /// `agy models` reaches the backend, so it needs more headroom than the
        /// other adapters' local credential checks.
        public var probeTimeout: Duration { .seconds(15) }

        public var capabilities: CLICapabilities {
            [
                .prompting, .sessions, .streaming, .structuredOutput,
                .modelSelection, .usageReporting, .additionalDirectories,
                .nativeOutputSchema, .fileAttachments, .modelDiscovery, .experimental,
            ]
        }

        public var environmentPolicy: EnvironmentPolicy {
            EnvironmentPolicy.base.inheriting([
                "ANTIGRAVITY_HOME", "GOOGLE_APPLICATION_CREDENTIALS", "GOOGLE_CLOUD_PROJECT",
            ])
        }

        // MARK: - Authentication

        /// `agy` ships no dedicated auth-status command, so this probes
        /// `agy models`, which requires valid credentials, returns quickly, and
        /// — critically — never opens a browser.
        ///
        /// The alternative considered and rejected was running a throwaway `-p`
        /// prompt: that costs the user tokens on every launch.
        public func authenticationStatus() async -> AuthenticationStatus {
            guard let result = await probe(["models"]) else {
                return .probeFailed(reason: "Could not run `agy models`")
            }

            let output = (result.standardOutputText + "\n" + result.standardErrorText).lowercased()
            if output.contains("not logged in")
                || output.contains("sign in")
                || output.contains("authenticate")
                || output.contains("unauthenticated") {
                return .requiresLogin(loginCommand: loginCommand)
            }
            guard result.exit.isSuccess else {
                return .requiresLogin(loginCommand: loginCommand)
            }
            // A model list means the backend accepted our credentials, but it
            // discloses no account identity.
            return .authenticated(AuthenticatedAccount(method: .keychain))
        }

        // MARK: - Models

        /// The live model catalogue from `agy models`.
        ///
        /// The only one of the four CLIs that can genuinely enumerate its
        /// models: `agy models` asks the backend and prints `id⇥Display Name`
        /// per line. That makes this list authoritative and complete — safe to
        /// render as an exhaustive picker — so this adapter ships no
        /// hand-maintained fallback. The trade-off is that it needs the network
        /// and valid credentials; without them it throws rather than guessing.
        public func availableModels() async throws -> [AgentModel] {
            guard let result = await probe(["models"]) else {
                throw AgenticCLIError.notInstalled(Self.identifier, installHint: installHint)
            }
            guard result.exit.isSuccess else {
                throw Translator.mapFailure(
                    exit: result.exit,
                    standardError: result.standardErrorText,
                    session: nil
                )
            }

            let models = Self.parseModels(result.standardOutputText)
            guard !models.isEmpty else {
                throw AgenticCLIError.malformedOutput(
                    reason: "`agy models` produced no recognisable entries",
                    raw: result.standardOutput
                )
            }
            return models
        }

        /// Parses the tab-separated `id⇥Display Name` lines `agy models` prints.
        ///
        /// The command also emits progress chatter ("Fetching available
        /// models…") that carries no tab, which is how those lines are told
        /// apart from entries.
        static func parseModels(_ output: String) -> [AgentModel] {
            var models: [AgentModel] = []
            for rawLine in output.split(separator: "\n") {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty else { continue }

                let fields = line.split(separator: "\t", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                guard fields.count == 2, !fields[0].isEmpty, !fields[0].contains(" ") else { continue }

                models.append(
                    AgentModel(id: fields[0], displayName: fields[1], origin: .catalog)
                )
            }
            return models
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
                        Log.info(.execution, "agy: \(arguments.count) args, \(Log.redacted(prompt))")
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
            additionalDirectories: [URL]? = nil
        ) throws -> [String] {
            if configuration.maximumTurns != nil {
                throw AgenticCLIError.unsupportedCapability(Self.identifier, .turnLimits)
            }
            if configuration.systemPromptAppendix != nil {
                throw AgenticCLIError.unsupportedCapability(Self.identifier, .systemPromptCustomization)
            }
            if !configuration.persistsSession {
                throw AgenticCLIError.unsupportedCapability(Self.identifier, .ephemeralRuns)
            }
            if let session {
                guard session.workingDirectory.standardizedFileURL
                    == configuration.workingDirectory.standardizedFileURL
                else {
                    throw AgenticCLIError.workingDirectoryMismatch(
                        session,
                        attempted: configuration.workingDirectory
                    )
                }
            }

            // `agy` populates `structured_output` only in `json` mode. Under
            // `stream-json` a schema run comes back with an empty response and
            // no structured field at all — verified against 1.1.13 — so a schema
            // forces the buffered format rather than silently returning nothing.
            let outputFormat = configuration.outputSchema == nil ? "stream-json" : "json"
            var arguments = ["--print", prompt, "--output-format", outputFormat]
            arguments += try permissionArguments(
                for: configuration.permissions,
                withOutputSchema: configuration.outputSchema != nil
            )

            if let session {
                arguments += ["--conversation", session.sessionID]
            }
            if let model = configuration.model {
                arguments += ["--model", model]
            }
            if let schema = configuration.outputSchema {
                // `agy` accepts the schema inline or as a path; inline avoids a
                // temporary file.
                arguments += ["--json-schema", try schema.jsonString()]
            }
            for directory in additionalDirectories ?? configuration.additionalDirectories {
                arguments += ["--add-dir", directory.path]
            }
            // Keep the CLI's own print timeout just inside ours, so it reports a
            // clean timeout before the kit resorts to killing the process tree.
            arguments += ["--print-timeout", Self.goDuration(configuration.timeout)]
            return arguments
        }

        /// - Parameter withOutputSchema: whether this run enforces a schema.
        ///   It changes the mapping: `agy` in plan mode writes a plan document
        ///   and returns an *empty* response with no `structured_output` when a
        ///   schema is also set — verified against 1.1.13. Rather than hand back
        ///   nothing, plan mode is refused and read-only drops to `--sandbox`,
        ///   which still denies edits because print mode cannot approve them.
        func permissionArguments(
            for policy: PermissionPolicy,
            withOutputSchema: Bool = false
        ) throws -> [String] {
            switch policy {
            case .planOnly:
                guard !withOutputSchema else {
                    throw AgenticCLIError.unsupportedPermissionPolicy(
                        Self.identifier,
                        policy,
                        reason: "agy's plan mode returns a plan document, not a structured result; "
                            + "use .readOnly for runs that need a schema"
                    )
                }
                return ["--mode", "plan"]
            case .readOnly:
                return withOutputSchema ? ["--sandbox"] : ["--mode", "plan", "--sandbox"]
            case .acceptingEdits:
                return ["--mode", "accept-edits"]
            case .allowingTools:
                // `agy` has no per-tool allowlist; it decides by mode.
                throw AgenticCLIError.unsupportedPermissionPolicy(
                    Self.identifier,
                    policy,
                    reason: "agy grants tools by mode, not by name"
                )
            case .unsafeBypassAll:
                return ["--dangerously-skip-permissions"]
            }
        }

        /// Formats a `Duration` the way Go's `flag` package parses it.
        static func goDuration(_ duration: Duration) -> String {
            let seconds = max(1, Int(duration.seconds.rounded()))
            return "\(seconds)s"
        }
    }
}
