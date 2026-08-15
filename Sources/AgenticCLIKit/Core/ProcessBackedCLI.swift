import Foundation

/// Turns a CLI's stdout into ``AgentEvent``s.
///
/// One translator instance handles one run, so it can hold the state a stream
/// needs — the session ID seen in the first event, accumulated assistant text,
/// the usage totals that only arrive at the end.
public protocol AgentOutputTranslating: Sendable {
    /// Maps one complete line of stdout to zero or more events.
    mutating func translate(line: String) -> [AgentEvent]

    /// Builds the terminal response once the process has exited.
    ///
    /// Throw here to turn a CLI-specific failure into a typed
    /// ``AgenticCLIError`` — this is where exit codes become meaning.
    mutating func makeResponse(
        exit: ProcessExit,
        rawOutput: Data,
        standardError: String,
        duration: Duration
    ) throws -> AgentResponse
}

/// Everything that has to happen before a CLI is spawned: attachments fetched
/// and made local, the prompt prefixed with what they are, the directories the
/// agent needs to read them, and a scratch area for CLIs that want a schema on
/// disk.
struct PreparedRun {
    var prompt: String
    var attachments: [ResolvedAttachment]
    /// The caller's directories plus any directory holding an attachment.
    var additionalDirectories: [URL]
    /// Non-`nil` only when something had to be written to disk. The caller owns
    /// it and must ``RunWorkspace/destroy()`` it when the run ends.
    var workspace: RunWorkspace?

    /// Attachments a CLI can hand over with a dedicated flag.
    var images: [ResolvedAttachment] {
        attachments.filter { $0.kind == PromptAttachment.Kind.image }
    }

    /// Attachments the agent has to open from disk itself.
    var nonImages: [ResolvedAttachment] {
        attachments.filter { $0.kind != PromptAttachment.Kind.image }
    }
}

/// Shared plumbing for adapters that drive a real executable.
///
/// Conformers supply the CLI-specific parts — which flags to pass, how to read
/// `--version`, how to probe auth — and inherit discovery, environment
/// construction, streaming, cancellation, and timeout handling.
public protocol ProcessBackedCLI: AgenticCLI {
    var runner: any ProcessRunner { get }
    var locator: any ExecutableLocating { get }
    /// Base environment plus this CLI's credential variables.
    var environmentPolicy: EnvironmentPolicy { get }
    /// Arguments that make the CLI print its version, usually `["--version"]`.
    var versionArguments: [String] { get }
    /// Hard ceiling for discovery and auth probes. Some CLIs block waiting for
    /// input when unauthenticated, so this is a correctness requirement, not a
    /// nicety.
    var probeTimeout: Duration { get }
    /// `true` for CLIs that take an output schema as a file path rather than
    /// inline. Declared in the protocol, not just the extension: a witness
    /// supplied only by an extension would never be dispatched to.
    var needsSchemaOnDisk: Bool { get }
}

extension ProcessBackedCLI {
    public var probeTimeout: Duration { .seconds(5) }
    public var versionArguments: [String] { ["--version"] }

    // MARK: - Discovery

    public func installation() async -> Installation {
        guard let executableURL = await locator.locate(executableName) else {
            Log.debug(.discovery, "\(identifier): \(executableName) not found")
            return .missing(
                cli: identifier,
                minimumSupportedVersion: minimumSupportedVersion,
                installHint: installHint
            )
        }

        let version = await readVersion(at: executableURL)
        Log.debug(.discovery, "\(identifier): \(version?.description ?? "unknown") at \(executableURL.path)")

        return Installation(
            cli: identifier,
            executableURL: executableURL,
            version: version,
            minimumSupportedVersion: minimumSupportedVersion,
            installHint: installHint
        )
    }

    func readVersion(at executableURL: URL) async -> SemanticVersion? {
        let invocation = ProcessInvocation(
            executableURL: executableURL,
            arguments: versionArguments,
            environment: environmentPolicy.resolved(againstHostEnvironment: hostEnvironment),
            standardInput: nil,
            timeout: probeTimeout,
            maximumOutputBytes: 64 * 1024
        )
        guard let result = try? await runner.run(invocation) else { return nil }
        // Some CLIs print the version to stderr; check both before giving up.
        return SemanticVersion(parsingFirstMatchIn: result.standardOutputText)
            ?? SemanticVersion(parsingFirstMatchIn: result.standardErrorText)
    }

    var hostEnvironment: [String: String] { ProcessInfo.processInfo.environment }

    /// Resolves the executable or throws ``AgenticCLIError/notInstalled(_:installHint:)``.
    public func resolveExecutable() async throws -> URL {
        guard let url = await locator.locate(executableName) else {
            throw AgenticCLIError.notInstalled(identifier, installHint: installHint)
        }
        return url
    }

    // MARK: - Probes

    /// Runs a short, non-interactive command with stdin closed.
    ///
    /// Returns `nil` when the probe could not run at all, which callers report
    /// as ``AuthenticationStatus/probeFailed(reason:)`` rather than guessing.
    func probe(_ arguments: [String], timeout: Duration? = nil) async -> ProcessResult? {
        guard let executableURL = await locator.locate(executableName) else { return nil }
        let invocation = ProcessInvocation(
            executableURL: executableURL,
            arguments: arguments,
            environment: environmentPolicy.resolved(againstHostEnvironment: hostEnvironment),
            standardInput: nil,
            timeout: timeout ?? probeTimeout,
            maximumOutputBytes: 1024 * 1024
        )
        return try? await runner.run(invocation)
    }

    // MARK: - Invocation building

    /// Builds a fully specified child invocation from a run configuration.
    func makeInvocation(
        arguments: [String],
        configuration: RunConfiguration
    ) async throws -> ProcessInvocation {
        let executableURL = try await resolveExecutable()

        if case .unsafeBypassAll = configuration.permissions {
            Log.fault(
                .execution,
                "\(identifier): running with unsafeBypassAll in \(configuration.workingDirectory.path)"
            )
        }

        return ProcessInvocation(
            executableURL: executableURL,
            arguments: arguments + configuration.extraArguments,
            workingDirectory: configuration.workingDirectory,
            environment: environmentPolicy.resolved(
                againstHostEnvironment: hostEnvironment,
                additionalOverrides: configuration.environmentOverrides
            ),
            standardInput: configuration.standardInput,
            timeout: configuration.timeout,
            maximumOutputBytes: configuration.maximumOutputBytes
        )
    }

    // MARK: - Run preparation

    /// Validates the configuration against this adapter's capabilities and
    /// resolves its attachments.
    ///
    /// Capability checks happen here rather than at the call site so that every
    /// adapter refuses the same things for the same reasons.
    func prepareRun(prompt: String, configuration: RunConfiguration) async throws -> PreparedRun {
        if configuration.outputSchema != nil {
            try requireCapabilities(.nativeOutputSchema)
        }
        if !configuration.attachments.isEmpty {
            try requireCapabilities(.fileAttachments)
        }

        var prepared = PreparedRun(
            prompt: prompt,
            attachments: [],
            additionalDirectories: configuration.additionalDirectories,
            workspace: nil
        )

        let needsWorkspace = configuration.attachments.contains { attachment in
            if case .file = attachment.source { return false }
            return true
        }
        if needsWorkspace || (configuration.outputSchema != nil && needsSchemaOnDisk) {
            prepared.workspace = try RunWorkspace()
        }

        guard !configuration.attachments.isEmpty else { return prepared }

        // A workspace is guaranteed above whenever a download or data blob is
        // present; pure file attachments never need one.
        let workspace = try prepared.workspace ?? {
            let workspace = try RunWorkspace()
            prepared.workspace = workspace
            return workspace
        }()

        let resolver = AttachmentResolver(maximumByteCount: configuration.maximumAttachmentBytes)
        let resolved = try await resolver.resolve(
            configuration.attachments,
            into: workspace,
            cli: identifier
        )

        prepared.attachments = resolved
        prepared.prompt = ResolvedAttachment.promptPreamble(for: resolved) + prompt

        let attachmentDirectories = ResolvedAttachment.requiredDirectories(
            for: resolved,
            workingDirectory: configuration.workingDirectory
        )
        for directory in attachmentDirectories
        where !prepared.additionalDirectories.contains(where: {
            $0.standardizedFileURL == directory.standardizedFileURL
        }) {
            prepared.additionalDirectories.append(directory)
        }

        Log.debug(.execution, "\(identifier): attached \(resolved.count) file(s)")
        return prepared
    }

    public var needsSchemaOnDisk: Bool { false }

    // MARK: - Streaming

    /// Drives one run: spawns the child, feeds stdout lines through
    /// `translator`, forwards stderr as diagnostics, and emits the terminal
    /// ``AgentEvent/finished(_:)``.
    func streamEvents(
        invocation: ProcessInvocation,
        translator: some AgentOutputTranslating
    ) -> AgentEventStream {
        let runner = self.runner
        let identifier = self.identifier

        return AgentEventStream { continuation in
            let task = Task {
                var translator = translator
                var standardOutputLines = LineAccumulator()
                var standardErrorLines = LineAccumulator()
                var rawOutput = Data()
                var standardErrorText = ""
                let clock = ContinuousClock()
                let started = clock.now

                do {
                    for try await event in runner.stream(invocation) {
                        try Task.checkCancellation()

                        switch event {
                        case let .standardOutput(chunk):
                            rawOutput.append(chunk)
                            for line in standardOutputLines.append(chunk) {
                                for agentEvent in translator.translate(line: line) {
                                    continuation.yield(agentEvent)
                                }
                            }

                        case let .standardError(chunk):
                            standardErrorText += String(decoding: chunk, as: UTF8.self)
                            for line in standardErrorLines.append(chunk) {
                                continuation.yield(.diagnostic(line))
                            }

                        case let .exited(exit):
                            // A CLI that exits without a trailing newline still
                            // owes us its last record.
                            if let line = standardOutputLines.flush() {
                                for agentEvent in translator.translate(line: line) {
                                    continuation.yield(agentEvent)
                                }
                            }
                            if let line = standardErrorLines.flush() {
                                continuation.yield(.diagnostic(line))
                            }

                            let response = try translator.makeResponse(
                                exit: exit,
                                rawOutput: rawOutput,
                                standardError: standardErrorText.trimmingCharacters(in: .whitespacesAndNewlines),
                                duration: clock.now - started
                            )
                            continuation.yield(.finished(response))
                            continuation.finish()
                            return
                        }
                    }
                    continuation.finish(
                        throwing: AgenticCLIError.malformedOutput(
                            reason: "Process ended without reporting an exit status",
                            raw: rawOutput
                        )
                    )
                } catch is CancellationError {
                    continuation.finish(throwing: AgenticCLIError.cancelled(identifier))
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
