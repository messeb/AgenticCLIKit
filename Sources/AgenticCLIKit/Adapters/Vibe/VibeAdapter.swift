import Foundation

extension Vibe {
    /// Drives Mistral's `vibe` CLI.
    ///
    /// Marked ``CLICapabilities/experimental``: `vibe` ships roughly weekly and
    /// its programmatic surface is still moving. The flags below are verified
    /// against 2.24.1.
    ///
    /// What is distinctive here, and what it costs:
    ///
    /// - **Turn limits.** The only adapter in this package that honours
    ///   ``RunConfiguration/maximumTurns``. `vibe` counts turns across the whole
    ///   session rather than the run, so resuming offsets the limit by the
    ///   session's existing step count — see ``Vibe/SessionLog``.
    /// - **Tokens and dollars.** Reported, but read from `vibe`'s session log
    ///   after the process exits, because none of it appears on stdout. Turning
    ///   session logging off in `config.toml` costs the usage, not the run.
    /// - **Model selection.** No flag; the alias goes in `VIBE_ACTIVE_MODEL`.
    ///   An unknown alias is *ignored* by `vibe`, so this adapter refuses one
    ///   instead of letting a run bill on a model nobody asked for.
    /// - **Trust.** Every run passes `--trust`. Without it `vibe` asks whether
    ///   the directory can be trusted, on a stdin that is closed.
    public struct Adapter: ProcessBackedCLI {
        public static let identifier = CLIIdentifier.vibe

        public let runner: any ProcessRunner
        public let locator: any ExecutableLocating
        /// Reads usage and step counts out of `vibe`'s own session log.
        /// Injectable so tests point at a fixture directory rather than the
        /// developer's real `~/.vibe`.
        public let sessionLog: SessionLog

        public init(
            runner: (any ProcessRunner)? = nil,
            locator: any ExecutableLocating = LoginShellExecutableLocator(),
            home: URL? = nil
        ) {
            self.runner = runner ?? SubprocessRunner(cli: .vibe)
            self.locator = locator
            self.sessionLog = SessionLog(
                home: home ?? SessionLog.resolvedHome(environment: ProcessInfo.processInfo.environment)
            )
        }

        public var displayName: String { "Mistral Vibe" }
        public var executableName: String { "vibe" }
        public var installHint: String {
            "Install with `uv tool install mistral-vibe`, then run `vibe --setup`"
        }
        public var loginCommand: String { "vibe --setup" }
        public var minimumSupportedVersion: SemanticVersion { SemanticVersion(2, 24, 0) }

        public var capabilities: CLICapabilities {
            [
                .prompting, .sessions, .streaming, .structuredOutput,
                .modelSelection, .turnLimits, .usageReporting, .toolAllowlist,
                .resumeAcrossDirectories, .additionalDirectories,
                .fileAttachments, .modelDiscovery, .experimental,
            ]
        }

        public var environmentPolicy: EnvironmentPolicy {
            EnvironmentPolicy.base.inheriting([
                "MISTRAL_API_KEY", Vibe.homeVariable, Vibe.modelVariable,
                "XDG_CONFIG_HOME",
            ])
        }

        // MARK: - Authentication

        /// Reports credential state without launching anything.
        ///
        /// `vibe` has no status command: `vibe --setup` is the login flow and it
        /// prompts, which no probe may do. So this reads what a completed login
        /// leaves behind:
        ///
        /// 1. `MISTRAL_API_KEY` in the environment, which takes precedence in
        ///    `vibe` itself.
        /// 2. A `MISTRAL_API_KEY` entry in `$VIBE_HOME/.env`, where both the
        ///    interactive setup and the browser sign-in store the key.
        ///
        /// Only the presence of a value is established — the key is never read
        /// out of the file, and never travels anywhere.
        ///
        /// A key on disk is evidence rather than proof: it can have been revoked
        /// since. Reporting ``AuthenticationStatus/undetectable(reason:)``
        /// instead would make a host app offer a login button to someone who is
        /// already signed in, which is the worse failure.
        public func authenticationStatus() async -> AuthenticationStatus {
            let environment = hostEnvironment
            if let key = environment["MISTRAL_API_KEY"], !key.isEmpty {
                return .authenticated(AuthenticatedAccount(
                    method: .environmentKey,
                    environmentVariable: "MISTRAL_API_KEY"
                ))
            }
            guard await locator.locate(executableName) != nil else {
                return .probeFailed(reason: "`vibe` is not installed")
            }
            guard hasStoredAPIKey else {
                return .requiresLogin(loginCommand: loginCommand)
            }
            return .authenticated(AuthenticatedAccount(method: .longLivedToken))
        }

        /// Whether `$VIBE_HOME/.env` defines a non-empty `MISTRAL_API_KEY`.
        var hasStoredAPIKey: Bool {
            guard let contents = try? String(
                contentsOf: sessionLog.home.appendingPathComponent(".env"),
                encoding: .utf8
            ) else { return false }

            return contents
                .split(separator: "\n", omittingEmptySubsequences: false)
                .contains { line in
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard trimmed.hasPrefix("MISTRAL_API_KEY"),
                          let equals = trimmed.firstIndex(of: "=")
                    else { return false }
                    let value = trimmed[trimmed.index(after: equals)...]
                        .trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    return !value.isEmpty
                }
        }

        // MARK: - Models

        /// The maintained ``Vibe/Model`` list, plus any alias the user defined,
        /// with their pinned `active_model` marked as the default.
        ///
        /// `vibe` cannot enumerate its models — the set lives in `config.toml`,
        /// which ships with three entries and is the user's to extend — so
        /// discovery is the bundled list merged with that file. Both halves
        /// matter: the bundled entries are what a fresh install has, and the
        /// configured ones are the only way to learn about a local model or a
        /// custom endpoint.
        public func availableModels() async throws -> [AgentModel] {
            let configuration = readConfiguration()
            let pinned = configuration.flatMap(Configuration.activeModel(fromTOML:))

            var models = Model.agentModels.map { model in
                guard let pinned else { return model }
                // A pinned alias outranks the list's own default: it is what a
                // run without an explicit model will actually use.
                return AgentModel(
                    id: model.id,
                    displayName: model.displayName,
                    summary: model.summary,
                    isDefault: model.id == pinned,
                    origin: model.origin
                )
            }

            let configured = configuration.map(Configuration.modelAliases(fromTOML:)) ?? []
            for alias in configured where !models.contains(where: { $0.id == alias }) {
                models.append(AgentModel(
                    id: alias,
                    summary: "Defined in config.toml",
                    isDefault: alias == pinned,
                    origin: .configuration
                ))
            }
            return models
        }

        /// Every alias `vibe` on this machine would resolve.
        func knownModelAliases() -> Set<String> {
            var aliases = Set(Model.allCases.map(\.rawValue))
            if let configuration = readConfiguration() {
                aliases.formUnion(Configuration.modelAliases(fromTOML: configuration))
            }
            return aliases
        }

        /// `$VIBE_HOME/config.toml`, when the user has one.
        ///
        /// Only the user-level file is read. A project's `.vibe/config.toml`
        /// also contributes at run time, but discovery has no working directory
        /// to look in, and reporting a model that only exists for one project as
        /// generally available would be worse than omitting it.
        func readConfiguration() -> String? {
            try? String(
                contentsOf: sessionLog.home.appendingPathComponent("config.toml"),
                encoding: .utf8
            )
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

                        let arguments = try makeArguments(
                            prompt: prepared.prompt,
                            session: session,
                            configuration: configuration,
                            additionalDirectories: prepared.additionalDirectories
                        )
                        let sessionLog = self.sessionLog
                        let translator = Translator(
                            workingDirectory: configuration.workingDirectory,
                            resumedSession: session,
                            usageProvider: { sessionLog.usage(forSessionID: $0) }
                        )
                        let invocation = try await makeInvocation(
                            arguments: arguments,
                            configuration: configuration.selectingModelByEnvironment()
                        )
                        Log.info(.execution, "vibe: \(arguments.count) args, \(Log.redacted(prompt))")

                        for try await event in streamEvents(invocation: invocation, translator: translator) {
                            // Usage only becomes readable once the process has
                            // exited, so the turn is reported as complete from
                            // the response rather than from a line of output.
                            if case let .finished(response) = event, let usage = response.usage {
                                continuation.yield(.turnCompleted(usage))
                            }
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

        /// Attachments take no argument of their own: `vibe` has no attachment
        /// flag, so `prepareRun` names the files in a preamble on the prompt and
        /// their directories arrive here as `additionalDirectories`.
        func makeArguments(
            prompt: String,
            session: SessionReference?,
            configuration: RunConfiguration,
            additionalDirectories: [URL]? = nil
        ) throws -> [String] {
            if configuration.systemPromptAppendix != nil {
                // `vibe` takes extra instructions from `AGENTS.md` files and a
                // configured prompt id, neither of which is a per-run flag, and
                // writing into someone's project to fake one is not this
                // package's call to make.
                throw AgenticCLIError.unsupportedCapability(Self.identifier, .systemPromptCustomization)
            }
            if !configuration.persistsSession {
                // Every run is written to the session log. There is no
                // equivalent of Claude's `--no-session-persistence`, and the log
                // is also where usage comes from.
                throw AgenticCLIError.unsupportedCapability(Self.identifier, .ephemeralRuns)
            }
            if let model = configuration.model {
                try validate(model: model)
            }

            var arguments = ["--prompt", prompt, "--output", "streaming"]
            // Non-interactive automation: without this, a directory `vibe` has
            // not seen before stops the run at a trust prompt on a closed stdin.
            arguments.append("--trust")
            arguments += try permissionArguments(for: configuration.permissions)

            if let session {
                arguments += ["--resume", session.sessionID]
            }
            if let maximumTurns = configuration.maximumTurns {
                arguments += ["--max-turns", String(turnLimit(maximumTurns, resuming: session))]
            }
            for directory in additionalDirectories ?? configuration.additionalDirectories {
                arguments += ["--add-dir", directory.path]
            }
            return arguments
        }

        /// Refuses a model alias `vibe` would silently ignore.
        ///
        /// `vibe` resolves `VIBE_ACTIVE_MODEL` against the aliases in its
        /// configuration and falls back to the default when it does not match —
        /// no warning, no failure, a bill on the wrong model. Refusing here is
        /// the same bargain the rest of this package makes: a typed error
        /// instead of a silent substitution.
        func validate(model: String) throws {
            let known = knownModelAliases()
            guard !known.contains(model) else { return }
            throw AgenticCLIError.unsupportedModel(
                Self.identifier,
                model: model,
                reason: "vibe selects models by the aliases in its config.toml (\(known.sorted().joined(separator: ", "))) "
                    + "and silently falls back to its default for anything else — add the model to "
                    + "~/.vibe/config.toml under [[models]] to use it"
            )
        }

        /// Translates "this many turns for this run" into the session-wide count
        /// `--max-turns` actually compares against.
        ///
        /// `vibe` stops a run when `steps - 1 >= max_turns`, where `steps` counts
        /// every model round trip the *session* has taken. Passing a caller's
        /// number straight through would therefore abort a resumed session
        /// immediately — `--max-turns 2` on a session that already took three
        /// steps never gets a turn. The session's existing step count is read
        /// from its log and added.
        ///
        /// When there is no log to read — session logging switched off — the
        /// number is passed through unchanged, because refusing the run over a
        /// missing convenience would be worse than a limit that is stricter than
        /// asked for.
        func turnLimit(_ maximumTurns: Int, resuming session: SessionReference?) -> Int {
            guard let session else { return maximumTurns }
            guard let steps = sessionLog.steps(forSessionID: session.sessionID) else {
                Log.debug(
                    .execution,
                    "vibe: no session log for \(session.sessionID); --max-turns counts the whole session"
                )
                return maximumTurns
            }
            return maximumTurns + steps
        }

        /// Maps a policy onto `vibe`'s agent profiles and tool filters.
        ///
        /// Two mechanisms, used together:
        ///
        /// - `--agent` picks a built-in profile: `plan` is read-only, and
        ///   `accept-edits` approves edits but still asks before running a
        ///   command — which, with no one to ask, means the command is refused.
        /// - `--enabled-tools` is an allowlist that, in programmatic mode,
        ///   disables everything it does not name. That is real enforcement, so
        ///   ``PermissionPolicy/readOnly`` is expressed as one rather than
        ///   approximated with a profile.
        ///
        /// `--auto-approve` accompanies the allowlist policies for a reason: the
        /// tools have already been constrained, and without it every call to one
        /// of them stops at an approval nobody can answer.
        func permissionArguments(for policy: PermissionPolicy) throws -> [String] {
            switch policy {
            case .planOnly:
                return ["--agent", "plan"]

            case .readOnly:
                // The plan profile is read-only too, but it also steers the
                // model into writing a plan. This says only "these tools", which
                // is what the policy means.
                var arguments = ["--agent", "plan", "--auto-approve"]
                for tool in Tool.readOnly { arguments += ["--enabled-tools", tool] }
                return arguments

            case let .allowingTools(allowed, denied):
                guard !allowed.isEmpty || !denied.isEmpty else {
                    // `--auto-approve` with neither list would approve every
                    // tool `vibe` has — the opposite of what naming an allowlist
                    // asks for.
                    throw AgenticCLIError.unsupportedPermissionPolicy(
                        Self.identifier,
                        policy,
                        reason: "an empty allowlist would leave every tool enabled and auto-approved"
                    )
                }
                var arguments = ["--agent", "accept-edits", "--auto-approve"]
                for tool in allowed { arguments += ["--enabled-tools", tool] }
                for tool in denied { arguments += ["--disabled-tools", tool] }
                return arguments

            case .acceptingEdits:
                // Edits are approved by the profile; `bash` still requires an
                // approval, and an unanswered approval is a denial.
                return ["--agent", "accept-edits"]

            case .unsafeBypassAll:
                return ["--agent", "auto-approve", "--auto-approve"]
            }
        }
    }
}

extension RunConfiguration {
    /// A copy that carries ``model`` in the environment, where `vibe` reads it.
    ///
    /// `vibe` has no `--model`; `VIBE_ACTIVE_MODEL` overrides `active_model` in
    /// `config.toml` for one process, which is exactly the scope a run wants.
    /// The caller's own overrides win, so a host app that sets the variable
    /// itself is not second-guessed.
    func selectingModelByEnvironment() -> RunConfiguration {
        guard let model else { return self }
        var copy = self
        if copy.environmentOverrides[Vibe.modelVariable] == nil {
            copy.environmentOverrides[Vibe.modelVariable] = model
        }
        return copy
    }
}
