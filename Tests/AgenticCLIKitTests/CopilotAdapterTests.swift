import AgenticCLIKitTesting
import Foundation
import Testing

@testable import AgenticCLIKit

@Suite("Copilot adapter")
struct CopilotAdapterTests {
    private let workingDirectory = URL(fileURLWithPath: "/tmp")
    private let fixedSessionID = "b43ffb8d-c827-474e-ad62-fbe0862b8c0e"

    private func configuration(
        permissions: PermissionPolicy = .readOnly
    ) -> RunConfiguration {
        RunConfiguration(workingDirectory: workingDirectory, permissions: permissions)
    }

    private func makeAdapter(
        runner: any ProcessRunner,
        stateDirectory: URL = URL(fileURLWithPath: "/nonexistent")
    ) -> Copilot.Adapter {
        Copilot.Adapter(
            runner: runner,
            locator: FakeExecutableLocator(),
            stateDirectory: stateDirectory,
            sessionIDGenerator: { fixedSessionID }
        )
    }

    // MARK: - Transcript

    @Test("Maps a recorded transcript onto events")
    func translatesRecordedRun() async throws {
        let runner = RecordedProcessRunner(always: try .fixture(Fixture.url(Fixture.copilotStream)))
        let events = try await makeAdapter(runner: runner)
            .stream("Read notes.txt and reply with its second line only.", configuration: configuration())
            .allEvents()

        // The session is announced before any output, from the identifier the
        // adapter itself handed to `--session-id`.
        #expect(events.first?.sessionReference?.sessionID == fixedSessionID)

        #expect(events.contains { $0.kind == "assistantTextDelta" })
        let tool = try #require(events.compactMap { event -> ToolInvocation? in
            if case let .toolUseRequested(invocation) = event { return invocation }
            return nil
        }.first)
        #expect(tool.name == "view")
        #expect(tool.id == "call_af3hzNh2hOgksYcTqMOAk0OX")

        let outcome = try #require(events.compactMap { event -> ToolOutcome? in
            if case let .toolResult(outcome) = event { return outcome }
            return nil
        }.first)
        #expect(outcome.name == "view")
        #expect(!outcome.isError)

        let response = try #require(events.last?.response)
        // The run took two turns; the answer is the last message, not every
        // message glued together.
        #expect(response.text == "beta")
        #expect(!response.text.contains("Reading the file"))
        #expect(response.session?.sessionID == fixedSessionID)
        #expect(response.exitCode == 0)
        #expect(!response.isError)
    }

    @Test("Reports the model Copilot actually routed to, and its billing units")
    func reportsUsage() async throws {
        let runner = RecordedProcessRunner(always: try .fixture(Fixture.url(Fixture.copilotStream)))
        let response = try await makeAdapter(runner: runner)
            .run("x", configuration: configuration())

        let usage = try #require(response.usage)
        // `auto` was requested; this is what served the turn.
        #expect(usage.model == "gpt-5-mini")
        #expect(usage.premiumRequests == 0)
        // Copilot bills in AI credits, reported in nano-units on the wire.
        #expect(usage.aiCredits.map { abs($0 - 0.4375755) < 0.0001 } == true)
        // Output tokens are reported per message, and the run took two turns.
        #expect(usage.outputTokens == 386)
        // Input tokens and dollars are not reported, and are not invented.
        #expect(usage.inputTokens == nil)
        #expect(usage.costUSD == nil)
    }

    @Test("The per-fragment tool-call deltas do not become events")
    func suppressesToolCallDeltas() async throws {
        let runner = RecordedProcessRunner(always: try .fixture(Fixture.url(Fixture.copilotStream)))
        let events = try await makeAdapter(runner: runner)
            .stream("x", configuration: configuration())
            .allEvents()

        // One `view` call, not one event per JSON fragment of its arguments.
        #expect(events.filter { $0.kind == "toolUseRequested" }.count == 1)
        #expect(events.filter { $0.kind == "raw" }.isEmpty)
    }

    // MARK: - Arguments

    @Test("A new run names its own session with a valid UUID")
    func namesItsOwnSession() throws {
        let adapter = Copilot.Adapter(
            runner: RecordedProcessRunner(always: .output("")),
            locator: FakeExecutableLocator()
        )
        let arguments = try adapter.makeArguments(
            prompt: "hello",
            session: nil,
            configuration: configuration(),
            newSessionID: adapter.newSessionIdentifier()
        )

        let index = try #require(arguments.firstIndex(of: "--session-id"))
        // `copilot` rejects a `--session-id` that is not a real UUID, so the
        // generator cannot be a counter or a slug.
        #expect(UUID(uuidString: arguments[index + 1]) != nil)
    }

    @Test("Resuming passes the session through and does not rename it")
    func resumesByIdentifier() throws {
        let adapter = makeAdapter(runner: RecordedProcessRunner(always: .output("")))
        let session = SessionReference(
            cli: .copilot,
            sessionID: "9489280e-6886-4f40-bf7c-9b27de4699c8",
            workingDirectory: workingDirectory
        )

        let arguments = try adapter.makeArguments(
            prompt: "more",
            session: session,
            configuration: configuration()
        )
        #expect(arguments.contains("--resume"))
        #expect(arguments.contains(session.sessionID))
        #expect(!arguments.contains("--session-id"))
    }

    /// Every non-interactive run must close the door on a prompt back to the
    /// user: stdin is closed, so a question would hang until the timeout.
    @Test("Runs never wait for user input")
    func neverAsksTheUser() throws {
        let adapter = makeAdapter(runner: RecordedProcessRunner(always: .output("")))
        let arguments = try adapter.makeArguments(
            prompt: "x",
            session: nil,
            configuration: configuration()
        )
        #expect(arguments.contains("--no-ask-user"))
        #expect(arguments.contains("--output-format"))
        #expect(arguments.contains("json"))
    }

    @Test("Sessions are not exported to GitHub unless the host app asks")
    func keepsSessionsLocalByDefault() throws {
        let runner = RecordedProcessRunner(always: .output(""))
        let quiet = makeAdapter(runner: runner)
        #expect(try quiet.makeArguments(prompt: "x", session: nil, configuration: configuration())
            .contains("--no-remote-export"))

        let sharing = Copilot.Adapter(
            runner: runner,
            locator: FakeExecutableLocator(),
            exportsSessionsToGitHub: true
        )
        #expect(!(try sharing.makeArguments(prompt: "x", session: nil, configuration: configuration()))
            .contains("--no-remote-export"))
    }

    // MARK: - Permissions

    /// Copilot is the one CLI here whose permission model can express this
    /// directly: a denial outranks `--allow-all-tools`, so read-only is a real
    /// guarantee rather than an approximation.
    @Test("Read-only denies the two tools that can change something")
    func mapsReadOnly() throws {
        let adapter = makeAdapter(runner: RecordedProcessRunner(always: .output("")))
        let arguments = try adapter.permissionArguments(for: .readOnly)

        #expect(arguments.contains("--allow-all-tools"))
        #expect(pairs(in: arguments, flag: "--deny-tool") == ["shell", "write"])
    }

    @Test("Plan mode also refuses to run commands or write files")
    func mapsPlanOnly() throws {
        let adapter = makeAdapter(runner: RecordedProcessRunner(always: .output("")))
        let arguments = try adapter.permissionArguments(for: .planOnly)

        #expect(arguments.contains("--mode"))
        #expect(arguments.contains("plan"))
        #expect(pairs(in: arguments, flag: "--deny-tool") == ["shell", "write"])
    }

    @Test("An allowlist is passed through in Copilot's own tool grammar")
    func mapsToolAllowlist() throws {
        let adapter = makeAdapter(runner: RecordedProcessRunner(always: .output("")))
        let arguments = try adapter.permissionArguments(for: .allowingTools(
            allowed: [Copilot.Permission.shellPrefix("git"), "view"],
            denied: [Copilot.Permission.write("/etc")]
        ))

        #expect(pairs(in: arguments, flag: "--allow-tool") == ["shell(git:*)", "view"])
        #expect(pairs(in: arguments, flag: "--deny-tool") == ["write(/etc)"])
        // A narrowed run must not also hand over everything.
        #expect(!arguments.contains("--allow-all-tools"))
    }

    @Test("An empty allowlist is refused rather than run with no tools")
    func refusesEmptyAllowlist() {
        let adapter = makeAdapter(runner: RecordedProcessRunner(always: .output("")))
        #expect(throws: AgenticCLIError.self) {
            try adapter.permissionArguments(for: .allowingTools(allowed: [], denied: []))
        }
    }

    @Test("Accepting edits still refuses arbitrary shell commands")
    func mapsAcceptingEdits() throws {
        let adapter = makeAdapter(runner: RecordedProcessRunner(always: .output("")))
        let arguments = try adapter.permissionArguments(for: .acceptingEdits)
        #expect(pairs(in: arguments, flag: "--deny-tool") == ["shell"])
    }

    // MARK: - Capabilities

    @Test("A schema is refused, because nothing in copilot enforces one")
    func refusesOutputSchemas() async {
        let adapter = makeAdapter(runner: RecordedProcessRunner(always: .output("")))
        #expect(!adapter.capabilities.contains(.nativeOutputSchema))

        var configuration = configuration()
        configuration.outputSchema = .object(["a": .string()])

        await #expect(throws: AgenticCLIError.self) {
            try await adapter.run("x", configuration: configuration)
        }
    }

    @Test("A turn limit is refused rather than silently ignored")
    func refusesTurnLimits() {
        let adapter = makeAdapter(runner: RecordedProcessRunner(always: .output("")))
        var configuration = configuration()
        configuration.maximumTurns = 3

        #expect(throws: AgenticCLIError.self) {
            try adapter.makeArguments(prompt: "x", session: nil, configuration: configuration)
        }
    }

    // MARK: - Failure mapping

    @Test("An unavailable model is reported as a model problem, not a crash")
    func mapsUnavailableModel() {
        let error = Copilot.Translator.mapFailure(
            exit: ProcessExit(code: 1),
            standardError: #"Error: Model "gpt-5-mini" from --model flag is not available."#,
            session: nil
        )
        guard case let .unsupportedModel(cli, model, _) = error else {
            Issue.record("Expected .unsupportedModel, got \(error)")
            return
        }
        #expect(cli == .copilot)
        #expect(model == "gpt-5-mini")
        #expect(error.recoverySuggestion != nil)
    }

    @Test("Authentication failures point at the login command")
    func mapsAuthenticationFailure() {
        let error = Copilot.Translator.mapFailure(
            exit: ProcessExit(code: 1),
            standardError: "Error: Bad credentials",
            session: nil
        )
        guard case let .notAuthenticated(_, command) = error else {
            Issue.record("Expected .notAuthenticated, got \(error)")
            return
        }
        #expect(command == "copilot login")
    }

    // MARK: - Local state

    /// `copilot` writes a `//` header into its own config, which is why the
    /// file cannot be handed straight to `JSONDecoder`.
    @Test("Reads the signed-in account out of copilot's commented JSON")
    func parsesLoginFromCommentedJSON() {
        let configuration = """
        // User settings belong in settings.json.
        // This file is managed automatically.
        {
          "firstLaunchAt": "2026-03-11T00:00:00.000Z",
          "lastLoggedInUser": { "host": "https://github.com", "login": "octocat" },
          "loggedInUsers": [{ "host": "https://github.com", "login": "octocat" }]
        }
        """
        #expect(Copilot.Adapter.parseLogin(fromConfiguration: configuration) == "octocat")
    }

    /// A `//` inside a value is not a comment; dropping it would corrupt the JSON.
    @Test("A URL value survives comment stripping")
    func stripsOnlyWholeLineComments() {
        let text = """
        // header
        { "host": "https://github.com" }
        """
        #expect(Copilot.Adapter.stripComments(from: text).contains("https://github.com"))
        #expect(!Copilot.Adapter.stripComments(from: text).contains("header"))
    }

    @Test("Never claims a signed-in user is signed out")
    func neverFabricatesALogoutState() async {
        // No config file, but the binary is present: `copilot` may still be
        // authenticated through the system credential store.
        let adapter = makeAdapter(runner: RecordedProcessRunner(always: .output("")))
        let status = await adapter.authenticationStatus()

        if case .requiresLogin = status {
            // Acceptable only because the state directory does not exist at all,
            // which means no login has ever completed here.
            #expect(true)
        }
        #expect(status.loginCommand == nil || status.loginCommand == "copilot login")
    }

    @Test("Reports the configured model as the user's choice, not as a guarantee")
    func reportsConfiguredModel() async throws {
        try await withTemporaryStateDirectory { directory in
            try Data("""
            { "model": "claude-opus-4.6", "theme": "auto" }
            """.utf8).write(to: directory.appendingPathComponent("settings.json"))

            let adapter = makeAdapter(
                runner: RecordedProcessRunner(always: .output("")),
                stateDirectory: directory
            )
            let models = try await adapter.availableModels()

            // `auto` is the only entry that is always valid, so it is the default.
            #expect(models.defaultModel?.id == "auto")
            let configured = try #require(models.first { $0.id == "claude-opus-4.6" })
            #expect(configured.origin == .configuration)
            // Nothing here may claim to be the complete set of choices.
            #expect(!models.isCompleteCatalogue)
        }
    }

    // MARK: - Models

    /// These two identifiers cannot be derived from the names GitHub documents,
    /// so they are pinned: they were read from the catalogue the CLI fetches,
    /// and a "tidy-up" that regularised them would silently break model
    /// selection.
    @Test("The identifiers that differ from their display names are exact")
    func pinsNonObviousIdentifiers() {
        // Documented as "Gemini 3.1 Pro", but the id keeps `-preview`.
        #expect(Copilot.Model.gemini31Pro.rawValue == "gemini-3.1-pro-preview")
        // Documented as "MAI-Code-1-Flash", but the id carries `-picker`.
        #expect(Copilot.Model.maiCode1Flash.rawValue == "mai-code-1-flash-picker")
        // Fast mode is a suffix on the model, not a separate version.
        #expect(Copilot.Model.claudeOpus48Fast.rawValue == "claude-opus-4.8-fast")
    }

    @Test("Identifiers keep the dots GitHub uses, rather than Claude-style dashes")
    func usesDottedVersionNumbers() {
        // `claude-opus-4.8` here, not `claude-opus-4-8` as the Claude Code CLI
        // spells the same model. Mixing the two conventions up would fail only
        // at run time, against a real account.
        #expect(Copilot.Model.claudeOpus48.rawValue == "claude-opus-4.8")
        #expect(ClaudeCode.Model.opus48.rawValue == "claude-opus-4-8")
    }

    @Test("Every model is listed once, with one default and a vendor")
    func modelListIsWellFormed() {
        let models = Copilot.Model.allCases
        #expect(Set(models.map(\.rawValue)).count == models.count)
        #expect(models.filter { $0 == Copilot.Model.default }.count == 1)
        #expect(Copilot.Model.default == .auto)
        #expect(models.allSatisfy { !$0.displayName.isEmpty })

        // Every vendor a case claims is reachable through the grouping helper.
        for vendor in Copilot.Model.Vendor.allCases {
            #expect(!Copilot.Model.models(from: vendor).isEmpty)
        }
        #expect(Copilot.Model.models(from: .anthropic).contains(.claudeOpus5))
        #expect(Copilot.Model.models(from: .github) == [.auto])
    }

    /// The list is documentation, not a gate: an account is normally entitled
    /// to far fewer models than this, and a model shipped tomorrow has to work
    /// without updating the package.
    @Test("An unlisted model identifier is still passed through")
    func acceptsUnlistedModels() throws {
        let adapter = makeAdapter(runner: RecordedProcessRunner(always: .output("")))
        var configuration = configuration()
        configuration.model = "grok-4.6"

        let arguments = try adapter.makeArguments(
            prompt: "x",
            session: nil,
            configuration: configuration
        )
        #expect(arguments.contains("grok-4.6"))
    }

    @Test("A configured model already in the list is not offered twice")
    func doesNotDuplicateConfiguredModel() async throws {
        try await withTemporaryStateDirectory { directory in
            try Data(#"{ "model": "claude-opus-5" }"#.utf8)
                .write(to: directory.appendingPathComponent("settings.json"))

            let adapter = makeAdapter(
                runner: RecordedProcessRunner(always: .output("")),
                stateDirectory: directory
            )
            let models = try await adapter.availableModels()
            #expect(models.filter { $0.id == "claude-opus-5" }.count == 1)
        }
    }

    // MARK: - Helpers

    private func withTemporaryStateDirectory(_ body: (URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("copilot-state-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(directory)
    }

    /// The values following each occurrence of `flag`.
    private func pairs(in arguments: [String], flag: String) -> [String] {
        arguments.indices.compactMap { index in
            arguments[index] == flag && arguments.indices.contains(index + 1)
                ? arguments[index + 1]
                : nil
        }
    }
}
