import Foundation

extension Copilot {
    /// Drives GitHub's `copilot` CLI.
    ///
    /// Not to be confused with `gh`, which manages repositories and takes no
    /// prompts; see ``Copilot`` for why only one of the two is an agent.
    ///
    /// `copilot` has the most expressive permission model of any CLI here: tools
    /// are named with patterns like `shell(git:*)`, and a denial always beats an
    /// allowance — including `--allow-all-tools`. That is what lets
    /// ``PermissionPolicy/readOnly`` and ``PermissionPolicy/allowingTools(allowed:denied:)``
    /// map onto real enforcement instead of an approximation.
    ///
    /// Two behaviours are worth knowing about:
    ///
    /// - Sessions get their identifier up front via `--session-id`, so
    ///   ``AgentEvent/sessionStarted(_:)`` arrives before the first token rather
    ///   than with the final event.
    /// - Session export to GitHub web and mobile is switched **off** by default
    ///   here — see ``exportsSessionsToGitHub``.
    ///
    /// Verified against GitHub Copilot CLI 1.0.80.
    public struct Adapter: ProcessBackedCLI {
        public static let identifier = CLIIdentifier.copilot

        public let runner: any ProcessRunner
        public let locator: any ExecutableLocating
        /// Whether to let `copilot` mirror sessions to GitHub web and mobile.
        ///
        /// Off by default. A library driving an agent on someone's behalf should
        /// not push their prompts and transcripts off the machine as a side
        /// effect of being called, so the adapter passes `--no-remote-export`
        /// unless a host app opts in.
        public let exportsSessionsToGitHub: Bool
        /// Where `copilot` keeps its own state. Injectable so tests can point at
        /// a fixture directory instead of the developer's real one.
        public let stateDirectory: URL
        /// Supplies the identifier handed to `--session-id`. Injectable so tests
        /// can assert on a fixed value.
        private let makeSessionID: @Sendable () -> String

        public init(
            runner: (any ProcessRunner)? = nil,
            locator: any ExecutableLocating = LoginShellExecutableLocator(),
            exportsSessionsToGitHub: Bool = false,
            stateDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".copilot", isDirectory: true),
            sessionIDGenerator: (@Sendable () -> String)? = nil
        ) {
            self.runner = runner ?? SubprocessRunner(cli: .copilot)
            self.locator = locator
            self.exportsSessionsToGitHub = exportsSessionsToGitHub
            self.stateDirectory = stateDirectory
            // `--session-id` rejects anything that is not a syntactically valid
            // UUID, so this cannot be a simple counter or a slug.
            self.makeSessionID = sessionIDGenerator ?? { UUID().uuidString.lowercased() }
        }

        public var displayName: String { "GitHub Copilot CLI" }
        public var executableName: String { "copilot" }
        public var installHint: String {
            "Install with `npm install -g @github/copilot`, then run `copilot login`"
        }
        public var loginCommand: String { "copilot login" }
        public var minimumSupportedVersion: SemanticVersion { SemanticVersion(1, 0, 0) }

        public var capabilities: CLICapabilities {
            [
                .prompting, .sessions, .streaming, .structuredOutput,
                .modelSelection, .usageReporting, .toolAllowlist,
                .additionalDirectories, .fileAttachments, .nativeImageAttachments,
                .modelDiscovery, .resumeAcrossDirectories,
            ]
        }

        public var environmentPolicy: EnvironmentPolicy {
            // `copilot` reads these in precedence order when no OAuth
            // credential is stored. Classic `ghp_` tokens are not accepted.
            EnvironmentPolicy.base.inheriting([
                "COPILOT_GITHUB_TOKEN", "GH_TOKEN", "GITHUB_TOKEN",
                "COPILOT_MODEL", "COPILOT_ALLOW_ALL", "XDG_CONFIG_HOME",
            ])
        }

        /// Environment variables `copilot` accepts a token in, most specific first.
        static let tokenVariables = ["COPILOT_GITHUB_TOKEN", "GH_TOKEN", "GITHUB_TOKEN"]

        /// The identifier a new run will claim with `--session-id`.
        func newSessionIdentifier() -> String { makeSessionID() }

        // MARK: - Authentication

        /// Reports login state without ever launching a browser.
        ///
        /// `copilot` has no status command — no `login --status`, no `whoami` —
        /// and `copilot login` opens a browser, which no launch probe may do. So
        /// this reads state instead of asking:
        ///
        /// 1. A token in the environment, in `copilot`'s own precedence order.
        /// 2. `~/.copilot/config.json`, which records who last signed in. The
        ///    file is JSON *with comments*, which is why it cannot simply be
        ///    handed to `JSONDecoder`.
        ///
        /// The token itself is never read — only the account name — and the
        /// secret stays in the system credential store where `copilot` put it.
        ///
        /// A recorded login is evidence, not proof: the credential behind it can
        /// have been revoked since. That is the same caveat every adapter here
        /// carries, and it beats the alternative of reporting
        /// ``AuthenticationStatus/undetectable(reason:)`` and making a host app
        /// show a login button to someone who is already signed in.
        public func authenticationStatus() async -> AuthenticationStatus {
            let environment = hostEnvironment
            if let variable = Self.tokenVariables.first(where: { !(environment[$0] ?? "").isEmpty }) {
                return .authenticated(
                    AuthenticatedAccount(method: .environmentKey, environmentVariable: variable)
                )
            }
            guard await locator.locate(executableName) != nil else {
                return .probeFailed(reason: "`copilot` is not installed")
            }
            guard let configuration = readStateFile("config.json") else {
                // No config file at all means the CLI has never completed a
                // login on this machine.
                return .requiresLogin(loginCommand: loginCommand)
            }
            guard let login = Self.parseLogin(fromConfiguration: configuration) else {
                return .undetectable(
                    reason: "copilot's config records no signed-in account, but its "
                        + "credentials live in the system credential store, so this is not conclusive"
                )
            }
            return .authenticated(AuthenticatedAccount(identifier: login, method: .oauth))
        }

        /// The `login` of the account `copilot` last signed in as.
        static func parseLogin(fromConfiguration text: String) -> String? {
            guard
                let data = stripComments(from: text).data(using: .utf8),
                let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { return nil }

            if let last = object["lastLoggedInUser"] as? [String: Any],
               let login = last["login"] as? String, !login.isEmpty {
                return login
            }
            for user in object["loggedInUsers"] as? [[String: Any]] ?? [] {
                if let login = user["login"] as? String, !login.isEmpty { return login }
            }
            return nil
        }

        /// Removes whole-line `//` comments, which `copilot` writes as a header
        /// into files that are otherwise plain JSON.
        ///
        /// Only lines that *begin* with `//` are dropped, so a `https://…` value
        /// inside the JSON survives.
        static func stripComments(from text: String) -> String {
            text
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
        }

        /// Reads a file out of ``stateDirectory``, or `nil` if it is not there.
        func readStateFile(_ name: String) -> String? {
            try? String(
                contentsOf: stateDirectory.appendingPathComponent(name),
                encoding: .utf8
            )
        }

        // MARK: - Models

        /// ``Copilot/Model/auto``, plus whatever model the user has configured.
        ///
        /// `copilot` will not enumerate its models and resolves the valid set
        /// against the signed-in account at launch, so this cannot be a complete
        /// catalogue and does not pretend to be one — see ``Copilot/Model`` for
        /// what was measured. The configured entry is tagged
        /// ``AgentModel/Origin/configuration`` precisely because it is the user's
        /// stated choice rather than a guarantee: a model named in `settings.json`
        /// can already have fallen out of the account's entitlements, in which
        /// case `copilot` warns and falls back to its default.
        public func availableModels() async throws -> [AgentModel] {
            var models = Model.agentModels
            // A configured model that is already in the maintained list is not
            // repeated — it is the same model, just chosen.
            if let configured = configuredModel(),
               !models.contains(where: { $0.id == configured }) {
                models.append(AgentModel(
                    id: configured,
                    summary: "Set in copilot's settings.json; may not be enabled for this account",
                    origin: .configuration
                ))
            }
            return models
        }

        /// The `model` value from `~/.copilot/settings.json`, if one is set.
        public func configuredModel() -> String? {
            readStateFile("settings.json").flatMap(Self.parseModel(fromSettings:))
        }

        static func parseModel(fromSettings text: String) -> String? {
            guard
                let data = stripComments(from: text).data(using: .utf8),
                let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                let model = object["model"] as? String,
                !model.isEmpty
            else { return nil }
            return model
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
                    var failure: (any Error)?

                    do {
                        if let session, session.cli != Self.identifier {
                            throw AgenticCLIError.sessionNotFound(session)
                        }

                        let prepared = try await prepareRun(prompt: prompt, configuration: configuration)
                        workspace = prepared.workspace

                        // A new run names its own session, so callers can record
                        // it before any output arrives.
                        let newSessionID = session == nil ? newSessionIdentifier() : nil
                        let arguments = try makeArguments(
                            prompt: prepared.prompt,
                            session: session,
                            configuration: configuration,
                            attachments: prepared.attachments,
                            additionalDirectories: prepared.additionalDirectories,
                            newSessionID: newSessionID
                        )
                        let translator = Translator(
                            workingDirectory: configuration.workingDirectory,
                            resumedSession: session,
                            expectedSessionID: newSessionID
                        )
                        let invocation = try await makeInvocation(
                            arguments: arguments,
                            configuration: configuration
                        )
                        Log.info(.execution, "copilot: \(arguments.count) args, \(Log.redacted(prompt))")

                        if let newSessionID {
                            continuation.yield(.sessionStarted(SessionReference(
                                cli: Self.identifier,
                                sessionID: newSessionID,
                                workingDirectory: configuration.workingDirectory,
                                model: configuration.model
                            )))
                        }
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
            attachments: [ResolvedAttachment] = [],
            additionalDirectories: [URL]? = nil,
            newSessionID: String? = nil
        ) throws -> [String] {
            if configuration.maximumTurns != nil {
                throw AgenticCLIError.unsupportedCapability(Self.identifier, .turnLimits)
            }
            if configuration.systemPromptAppendix != nil {
                throw AgenticCLIError.unsupportedCapability(Self.identifier, .systemPromptCustomization)
            }
            if !configuration.persistsSession {
                // Every `copilot` run is written to its session store; there is
                // no equivalent of Claude's `--no-session-persistence`.
                throw AgenticCLIError.unsupportedCapability(Self.identifier, .ephemeralRuns)
            }

            var arguments = ["--prompt", prompt, "--output-format", "json"]
            // Without this, a turn that wants to consult the user blocks forever
            // on a stdin that is closed.
            arguments.append("--no-ask-user")
            arguments += try permissionArguments(for: configuration.permissions)

            if let session {
                arguments += ["--resume", session.sessionID]
            } else if let newSessionID {
                arguments += ["--session-id", newSessionID]
            }
            if let model = configuration.model {
                arguments += ["--model", model]
            }
            if !exportsSessionsToGitHub {
                arguments.append("--no-remote-export")
            }
            // `--attachment` takes images and documents alike, so nothing here
            // has to be smuggled in through the prompt.
            for attachment in attachments {
                arguments += ["--attachment", attachment.url.path]
            }
            for directory in additionalDirectories ?? configuration.additionalDirectories {
                arguments += ["--add-dir", directory.path]
            }
            return arguments
        }

        /// Maps a policy onto `copilot`'s tool grammar.
        ///
        /// The mappings lean on one guarantee from `copilot`'s own permission
        /// documentation: a `--deny-tool` always wins over any allowance,
        /// `--allow-all-tools` included. That is why read-only can be built as
        /// "allow everything, then deny the two kinds of tool that can change
        /// something" rather than by enumerating a safe list that would go stale
        /// the moment a tool is added.
        func permissionArguments(for policy: PermissionPolicy) throws -> [String] {
            switch policy {
            case .planOnly:
                // Plan mode still reads the workspace to write its plan; the
                // denials keep it from doing anything else.
                return [
                    "--mode", "plan",
                    "--allow-all-tools",
                    "--deny-tool", Permission.shell,
                    "--deny-tool", Permission.write,
                ]

            case .readOnly:
                return [
                    "--allow-all-tools",
                    "--deny-tool", Permission.shell,
                    "--deny-tool", Permission.write,
                ]

            case let .allowingTools(allowed, denied):
                var arguments: [String] = []
                for tool in allowed { arguments += ["--allow-tool", tool] }
                for tool in denied { arguments += ["--deny-tool", tool] }
                guard !arguments.isEmpty else {
                    throw AgenticCLIError.unsupportedPermissionPolicy(
                        Self.identifier,
                        policy,
                        reason: "an empty allowlist would leave the run with no tools at all"
                    )
                }
                return arguments

            case .acceptingEdits:
                // Edits yes, arbitrary commands no.
                return ["--allow-all-tools", "--deny-tool", Permission.shell]

            case .unsafeBypassAll:
                return ["--allow-all-tools"]
            }
        }
    }
}
