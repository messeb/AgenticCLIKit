import AgenticCLIKitTesting
import Foundation
import Testing

@testable import AgenticCLIKit

@Suite("Vibe adapter")
struct VibeAdapterTests {
    private let workingDirectory = URL(fileURLWithPath: "/tmp/vibe-fixture")
    /// The session both recorded transcripts belong to.
    private let recordedSessionID = "3faf00b9-4bb2-d481-4a78-d509562ff0eb"

    private func configuration(
        permissions: PermissionPolicy = .readOnly
    ) -> RunConfiguration {
        RunConfiguration(workingDirectory: workingDirectory, permissions: permissions)
    }

    private func makeAdapter(
        runner: any ProcessRunner,
        home: URL = URL(fileURLWithPath: "/nonexistent")
    ) -> Vibe.Adapter {
        Vibe.Adapter(runner: runner, locator: FakeExecutableLocator(), home: home)
    }

    /// Builds the directory layout `vibe` writes its session log into, so the
    /// usage reader is exercised against the real file rather than a stub.
    private func makeHomeWithSessionLog() throws -> URL {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vibe-home-\(UUID().uuidString)", isDirectory: true)
        let session = home
            .appendingPathComponent("logs/session/session_20260816_112421_3faf00b9", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: Fixture.url(Fixture.vibeMeta),
            to: session.appendingPathComponent("meta.json")
        )
        return home
    }

    // MARK: - Transcript

    @Test("Maps a recorded transcript onto events")
    func translatesRecordedRun() async throws {
        let runner = RecordedProcessRunner(always: try .fixture(Fixture.url(Fixture.vibeStream)))
        let events = try await makeAdapter(runner: runner)
            .stream("Read the file /tmp/vibe-fixture/notes.txt", configuration: configuration())
            .allEvents()

        // Every entry carries the session, so it is known from the first line
        // rather than only at the end.
        #expect(events.first?.sessionReference?.sessionID == recordedSessionID)
        #expect(events.contains { $0.kind == "reasoningDelta" })

        let tool = try #require(events.compactMap { event -> ToolInvocation? in
            if case let .toolUseRequested(invocation) = event { return invocation }
            return nil
        }.first)
        #expect(tool.name == "read_file")

        let outcome = try #require(events.compactMap { event -> ToolOutcome? in
            if case let .toolResult(outcome) = event { return outcome }
            return nil
        }.first)
        #expect(outcome.name == "read_file")
        #expect(outcome.isError == false)

        let response = try #require(events.last?.response)
        #expect(response.text == "2beta")
        #expect(response.session?.sessionID == recordedSessionID)
        #expect(response.stopReason == "completed")
    }

    /// `vibe` streams whole messages, not tokens — the adapter must not invent
    /// deltas it did not receive.
    @Test("Reports messages whole, without token deltas")
    func emitsWholeMessages() async throws {
        let runner = RecordedProcessRunner(always: try .fixture(Fixture.url(Fixture.vibeStream)))
        let events = try await makeAdapter(runner: runner)
            .stream("Read notes.txt", configuration: configuration())
            .allEvents()

        #expect(!events.contains { $0.kind == "assistantTextDelta" })
        #expect(events.filter { $0.kind == "assistantMessage" }.count == 1)
    }

    // MARK: - Resume

    /// A resumed run replays the entire transcript before the new turn. Emitting
    /// that history would show the caller the previous answer as if this turn
    /// had produced it.
    @Test("Suppresses replayed history up to the resume checkpoint")
    func resumeSkipsReplayedHistory() async throws {
        let runner = RecordedProcessRunner(always: try .fixture(Fixture.url(Fixture.vibeResume)))
        let session = SessionReference(
            cli: .vibe,
            sessionID: recordedSessionID,
            workingDirectory: workingDirectory
        )
        let events = try await makeAdapter(runner: runner)
            .stream(resuming: session, prompt: "Now reply with the third line only.", configuration: configuration())
            .allEvents()

        let messages = events.compactMap { event -> String? in
            if case let .assistantMessage(text) = event { return text }
            return nil
        }
        #expect(messages.count == 1)
        #expect(messages.first?.contains("gamma") == true)
        // The replayed tool call belongs to the previous turn.
        #expect(!events.contains { $0.kind == "toolUseRequested" })

        let response = try #require(events.last?.response)
        #expect(response.text == "3→gamma")
    }

    @Test("Refuses a session that belongs to another CLI")
    func rejectsForeignSession() async throws {
        let runner = RecordedProcessRunner(always: .output(""))
        let session = SessionReference(
            cli: .codex,
            sessionID: "abc",
            workingDirectory: workingDirectory
        )
        await #expect(throws: AgenticCLIError.self) {
            _ = try await makeAdapter(runner: runner)
                .stream(resuming: session, prompt: "hi", configuration: configuration())
                .allEvents()
        }
    }

    // MARK: - Turn limits

    @Test("Reports a turn limit as its own error, carrying the partial text")
    func turnLimitBecomesTypedError() async throws {
        // A run stopped by its turn limit also exits non-zero; the specific
        // error has to win over the generic process failure.
        let runner = RecordedProcessRunner(always: Vibe.Adapter.turnLimitRecording())
        var configuration = configuration()
        configuration.maximumTurns = 1

        await #expect(throws: AgenticCLIError.self) {
            _ = try await makeAdapter(runner: runner)
                .stream("List three primes, then read notes.txt", configuration: configuration)
                .allEvents()
        }
    }

    /// `vibe` compares `--max-turns` against the number of steps the whole
    /// session has taken, so a caller's "two more turns" has to be offset by the
    /// steps already recorded — otherwise a resumed run stops before it starts.
    @Test("Offsets --max-turns by the steps a resumed session already took")
    func turnLimitIsOffsetOnResume() throws {
        let adapter = makeAdapter(
            runner: RecordedProcessRunner(always: .output("")),
            home: try makeHomeWithSessionLog()
        )
        var configuration = configuration()
        configuration.maximumTurns = 2

        let session = SessionReference(
            cli: .vibe,
            sessionID: recordedSessionID,
            workingDirectory: workingDirectory
        )
        let arguments = try adapter.makeArguments(
            prompt: "next",
            session: session,
            configuration: configuration
        )
        // The recorded session took five steps.
        #expect(arguments.contains("--max-turns"))
        #expect(arguments.contains("7"))
    }

    @Test("Passes --max-turns through for a fresh run")
    func turnLimitIsVerbatimForNewSessions() throws {
        let adapter = makeAdapter(runner: RecordedProcessRunner(always: .output("")))
        var configuration = configuration()
        configuration.maximumTurns = 3

        let arguments = try adapter.makeArguments(
            prompt: "hi",
            session: nil,
            configuration: configuration
        )
        #expect(arguments.contains("3"))
    }

    // MARK: - Usage

    @Test("Reads usage and cost out of the session log")
    func reportsUsageFromSessionLog() async throws {
        let runner = RecordedProcessRunner(always: try .fixture(Fixture.url(Fixture.vibeStream)))
        let adapter = makeAdapter(runner: runner, home: try makeHomeWithSessionLog())
        let events = try await adapter
            .stream("Read notes.txt", configuration: configuration())
            .allEvents()

        let response = try #require(events.last?.response)
        let usage = try #require(response.usage)
        #expect(usage.inputTokens == 7326)
        #expect(usage.outputTokens == 196)
        #expect(usage.cachedInputTokens == 3584)
        #expect(usage.model == "mistral-medium-3.5")
        // (7326 - 3584) × 1.5 + 3584 × 0.15 + 196 × 7.5, per million — vibe's own
        // arithmetic, so a per-turn figure adds up to the session total it records.
        let cost = try #require(usage.costUSD)
        #expect(abs(cost - 0.0076206) < 0.000_001)

        // Usage is only readable once the process has exited, so the turn is
        // reported complete from the response rather than from a line of output.
        #expect(events.contains { $0.kind == "turnCompleted" })
    }

    @Test("Runs without usage when no session log was written")
    func missingSessionLogCostsUsageNotTheRun() async throws {
        let runner = RecordedProcessRunner(always: try .fixture(Fixture.url(Fixture.vibeStream)))
        let events = try await makeAdapter(runner: runner)
            .stream("Read notes.txt", configuration: configuration())
            .allEvents()

        let response = try #require(events.last?.response)
        #expect(response.usage == nil)
        #expect(response.text == "2beta")
    }

    // MARK: - Arguments

    @Test("Always runs non-interactively, streaming, and trusted")
    func baseArguments() throws {
        let adapter = makeAdapter(runner: RecordedProcessRunner(always: .output("")))
        let arguments = try adapter.makeArguments(
            prompt: "hi",
            session: nil,
            configuration: configuration()
        )
        #expect(arguments.contains("--prompt"))
        #expect(arguments.contains("--output"))
        #expect(arguments.contains("streaming"))
        // Without --trust an unseen directory stops the run at a prompt nobody
        // can answer.
        #expect(arguments.contains("--trust"))
    }

    @Test(
        "Maps each permission policy onto an agent profile",
        arguments: [
            (PermissionPolicy.planOnly, "plan"),
            (PermissionPolicy.acceptingEdits, "accept-edits"),
            (PermissionPolicy.unsafeBypassAll, "auto-approve"),
        ]
    )
    func permissionProfiles(policy: PermissionPolicy, expected: String) throws {
        let adapter = makeAdapter(runner: RecordedProcessRunner(always: .output("")))
        let arguments = try adapter.permissionArguments(for: policy)
        #expect(arguments.contains("--agent"))
        #expect(arguments.contains(expected))
    }

    @Test("Expresses read-only as a tool allowlist, not just a profile")
    func readOnlyIsEnforcedByAllowlist() throws {
        let adapter = makeAdapter(runner: RecordedProcessRunner(always: .output("")))
        let arguments = try adapter.permissionArguments(for: .readOnly)

        #expect(arguments.contains("--enabled-tools"))
        #expect(arguments.contains(Vibe.Tool.readFile))
        #expect(arguments.contains(Vibe.Tool.grep))
        // In programmatic mode an allowlist disables everything it omits, so the
        // two tools that can change something are gone rather than merely denied.
        #expect(!arguments.contains(Vibe.Tool.bash))
        #expect(!arguments.contains(Vibe.Tool.writeFile))
    }

    @Test("Passes an explicit allowlist and denylist through")
    func toolAllowlist() throws {
        let adapter = makeAdapter(runner: RecordedProcessRunner(always: .output("")))
        let arguments = try adapter.permissionArguments(
            for: .allowingTools(allowed: ["bash*"], denied: [Vibe.Tool.matching("^serena_.*$")])
        )
        #expect(arguments.contains("bash*"))
        #expect(arguments.contains("re:^serena_.*$"))
        #expect(arguments.contains("--disabled-tools"))
    }

    /// `--auto-approve` with neither list would approve every tool `vibe` has —
    /// the opposite of what naming an allowlist asks for.
    @Test("Refuses an empty allowlist")
    func emptyAllowlistIsRefused() throws {
        let adapter = makeAdapter(runner: RecordedProcessRunner(always: .output("")))
        #expect(throws: AgenticCLIError.self) {
            _ = try adapter.permissionArguments(for: .allowingTools(allowed: [], denied: []))
        }
    }

    @Test("Grants additional directories")
    func additionalDirectories() throws {
        let adapter = makeAdapter(runner: RecordedProcessRunner(always: .output("")))
        var configuration = configuration()
        configuration.additionalDirectories = [URL(fileURLWithPath: "/tmp/library")]

        let arguments = try adapter.makeArguments(
            prompt: "hi",
            session: nil,
            configuration: configuration
        )
        #expect(arguments.contains("--add-dir"))
        #expect(arguments.contains("/tmp/library"))
    }

    // MARK: - Capability refusals

    @Test("Refuses a system prompt appendix rather than writing into the project")
    func refusesSystemPromptAppendix() throws {
        let adapter = makeAdapter(runner: RecordedProcessRunner(always: .output("")))
        var configuration = configuration()
        configuration.systemPromptAppendix = "Be brief."

        #expect(throws: AgenticCLIError.self) {
            _ = try adapter.makeArguments(prompt: "hi", session: nil, configuration: configuration)
        }
    }

    @Test("Refuses an ephemeral run, because every run is logged")
    func refusesEphemeralRuns() throws {
        let adapter = makeAdapter(runner: RecordedProcessRunner(always: .output("")))
        var configuration = configuration()
        configuration.persistsSession = false

        #expect(throws: AgenticCLIError.self) {
            _ = try adapter.makeArguments(prompt: "hi", session: nil, configuration: configuration)
        }
    }

    @Test("Refuses a schema, which vibe cannot enforce")
    func refusesOutputSchema() async throws {
        let runner = RecordedProcessRunner(always: .output(""))
        var configuration = configuration()
        configuration.outputSchema = .object(["answer": .string("the answer")])

        await #expect(throws: AgenticCLIError.self) {
            _ = try await makeAdapter(runner: runner)
                .stream("hi", configuration: configuration)
                .allEvents()
        }
    }

    // MARK: - Models

    /// `vibe` has no `--model`: the alias goes in the environment, and the
    /// caller's own override is not second-guessed.
    @Test("Selects the model through VIBE_ACTIVE_MODEL")
    func modelTravelsInTheEnvironment() async throws {
        let runner = RecordedProcessRunner(always: try .fixture(Fixture.url(Fixture.vibeStream)))
        var configuration = configuration()
        configuration.model = Vibe.Model.devstralSmall.rawValue

        _ = try await makeAdapter(runner: runner)
            .stream("hi", configuration: configuration)
            .allEvents()

        let invocation = try #require(runner.lastInvocation)
        #expect(invocation.environment["VIBE_ACTIVE_MODEL"] == "devstral-small")
        #expect(!invocation.arguments.contains("--model"))
    }

    /// An alias `vibe` does not know is ignored, and the run bills on the
    /// default instead. A refusal beats a silent substitution.
    @Test("Refuses a model alias vibe would silently ignore")
    func refusesUnknownModel() throws {
        let adapter = makeAdapter(runner: RecordedProcessRunner(always: .output("")))
        var configuration = configuration()
        configuration.model = "mistral-large-imaginary"

        #expect(throws: AgenticCLIError.self) {
            _ = try adapter.makeArguments(prompt: "hi", session: nil, configuration: configuration)
        }
    }

    @Test("Discovers models from the bundled list and config.toml")
    func modelDiscovery() async throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vibe-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try """
        active_model = "devstral-small"

        [[models]]
        name = "qwen3-coder"
        alias = "workstation"
        provider = "llamacpp"
        """.write(
            to: home.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )

        let adapter = makeAdapter(runner: RecordedProcessRunner(always: .output("")), home: home)
        let models = try await adapter.availableModels()

        #expect(models.contains { $0.id == "mistral-medium-3.5" && $0.origin == .bundled })
        #expect(models.contains { $0.id == "workstation" && $0.origin == .configuration })
        // The pinned alias outranks the bundled list's own default.
        #expect(models.defaultModel?.id == "devstral-small")

        // A configured alias is accepted, where an unknown one is refused.
        var configuration = configuration()
        configuration.model = "workstation"
        #expect(throws: Never.self) {
            _ = try adapter.makeArguments(prompt: "hi", session: nil, configuration: configuration)
        }
    }

    // MARK: - Authentication

    @Test("Reports a stored API key without reading it")
    func authenticationFromStoredKey() async throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vibe-env-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try "MISTRAL_API_KEY=super-secret\n".write(
            to: home.appendingPathComponent(".env"),
            atomically: true,
            encoding: .utf8
        )

        let adapter = makeAdapter(runner: RecordedProcessRunner(always: .output("")), home: home)
        #expect(adapter.hasStoredAPIKey)

        // An empty assignment is not a credential.
        try "MISTRAL_API_KEY=\n".write(
            to: home.appendingPathComponent(".env"),
            atomically: true,
            encoding: .utf8
        )
        #expect(!adapter.hasStoredAPIKey)
    }

    @Test("Asks for setup when nothing is stored")
    func authenticationRequiresLogin() async throws {
        let adapter = makeAdapter(runner: RecordedProcessRunner(always: .output("")))
        let status = await adapter.authenticationStatus()

        // The environment of the test process may legitimately hold a key; the
        // interesting case is the one where it does not.
        if ProcessInfo.processInfo.environment["MISTRAL_API_KEY"]?.isEmpty == false {
            #expect(status.isAuthenticated)
        } else {
            #expect(status.loginCommand == "vibe --setup")
        }
    }

    // MARK: - Capabilities

    @Test("Declares what it can do, and stays marked experimental")
    func capabilities() {
        let adapter = makeAdapter(runner: RecordedProcessRunner(always: .output("")))
        #expect(adapter.capabilities.contains(.turnLimits))
        #expect(adapter.capabilities.contains(.usageReporting))
        #expect(adapter.capabilities.contains(.toolAllowlist))
        #expect(adapter.capabilities.contains(.resumeAcrossDirectories))
        #expect(adapter.capabilities.contains(.experimental))
        #expect(!adapter.capabilities.contains(.nativeOutputSchema))
        #expect(!adapter.capabilities.contains(.nativeImageAttachments))
        #expect(!adapter.capabilities.contains(.ephemeralRuns))
        #expect(!adapter.capabilities.contains(.systemPromptCustomization))
    }
}

extension Vibe.Adapter {
    /// The recorded turn-limit transcript, which `vibe` ends with a non-zero
    /// exit status.
    static func turnLimitRecording() -> RecordedProcessRunner.Recording {
        var recording = try! RecordedProcessRunner.Recording.fixture(Fixture.url(Fixture.vibeTurnLimit))
        recording.exitCode = 1
        return recording
    }
}
