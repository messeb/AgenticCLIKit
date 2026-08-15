import AgenticCLIKitTesting
import Foundation
import Testing

@testable import AgenticCLIKit

@Suite("Antigravity adapter")
struct AntigravityAdapterTests {
    private func makeAdapter(_ runner: RecordedProcessRunner) -> Antigravity.Adapter {
        Antigravity.Adapter(runner: runner, locator: FakeExecutableLocator())
    }

    private let workingDirectory = URL(fileURLWithPath: "/tmp/agentickit-tests")

    private func configuration(_ permissions: PermissionPolicy = .readOnly) -> RunConfiguration {
        RunConfiguration(workingDirectory: workingDirectory, permissions: permissions, timeout: .seconds(120))
    }

    // MARK: - Capabilities

    /// The PRD expected this adapter to be text-only. The shipped CLI has
    /// `--output-format stream-json` with conversation IDs and usage — it is
    /// only discoverable via `agy help`, not `agy --help`.
    @Test("Structured output and sessions are supported, and the adapter says it is experimental")
    func declaresCapabilities() {
        let adapter = makeAdapter(RecordedProcessRunner(always: .output("")))
        #expect(adapter.capabilities.contains(.structuredOutput))
        #expect(adapter.capabilities.contains(.streaming))
        #expect(adapter.capabilities.contains(.sessions))
        #expect(adapter.capabilities.contains(.experimental))
        // Undocumented, so not claimed.
        #expect(!adapter.capabilities.contains(.resumeAcrossDirectories))
    }

    // MARK: - Argument construction

    @Test("Print mode requests stream-json and bounds the CLI's own timeout")
    func buildsPrintArguments() throws {
        let adapter = makeAdapter(RecordedProcessRunner(always: .output("")))
        let arguments = try adapter.makeArguments(prompt: "hello", session: nil, configuration: configuration())

        #expect(arguments.starts(with: ["--print", "hello"]))
        #expect(arguments.contains("stream-json"))
        // Go's flag package parses durations like "120s".
        let timeoutIndex = try #require(arguments.firstIndex(of: "--print-timeout"))
        #expect(arguments[timeoutIndex + 1] == "120s")
    }

    @Test(
        "Permission policies map onto modes",
        arguments: [
            (PermissionPolicy.planOnly, ["--mode", "plan"]),
            (.readOnly, ["--mode", "plan", "--sandbox"]),
            (.acceptingEdits, ["--mode", "accept-edits"]),
            (.unsafeBypassAll, ["--dangerously-skip-permissions"]),
        ]
    )
    func mapsPermissionPolicies(policy: PermissionPolicy, expected: [String]) throws {
        let adapter = makeAdapter(RecordedProcessRunner(always: .output("")))
        #expect(try adapter.permissionArguments(for: policy) == expected)
    }

    @Test("A tool allowlist is refused; `agy` decides by mode")
    func refusesToolAllowlist() {
        let adapter = makeAdapter(RecordedProcessRunner(always: .output("")))
        #expect(throws: AgenticCLIError.self) {
            try adapter.permissionArguments(for: .allowingTools(["Read"]))
        }
    }

    @Test("Resume passes --conversation")
    func buildsResumeArguments() throws {
        let adapter = makeAdapter(RecordedProcessRunner(always: .output("")))
        let session = SessionReference(cli: .antigravity, sessionID: "c-1", workingDirectory: workingDirectory)
        let arguments = try adapter.makeArguments(
            prompt: "more",
            session: session,
            configuration: configuration()
        )

        #expect(arguments.contains("--conversation"))
        #expect(arguments.contains("c-1"))
    }

    /// Without documented cross-directory resume, sending a session to a
    /// different directory is refused here rather than failing confusingly
    /// inside the CLI.
    @Test("Resuming from another directory is refused")
    func refusesCrossDirectoryResume() {
        let adapter = makeAdapter(RecordedProcessRunner(always: .output("")))
        let session = SessionReference(
            cli: .antigravity,
            sessionID: "c-1",
            workingDirectory: URL(fileURLWithPath: "/elsewhere")
        )

        do {
            _ = try adapter.makeArguments(prompt: "more", session: session, configuration: configuration())
            Issue.record("Expected a refusal")
        } catch let error as AgenticCLIError {
            guard case .workingDirectoryMismatch = error else {
                Issue.record("Expected .workingDirectoryMismatch, got \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Unsupported options are refused rather than dropped")
    func refusesUnsupportedOptions() {
        let adapter = makeAdapter(RecordedProcessRunner(always: .output("")))

        var ephemeral = configuration()
        ephemeral.persistsSession = false
        #expect(throws: AgenticCLIError.self) {
            try adapter.makeArguments(prompt: "x", session: nil, configuration: ephemeral)
        }

        var withSystemPrompt = configuration()
        withSystemPrompt.systemPromptAppendix = "Be terse."
        #expect(throws: AgenticCLIError.self) {
            try adapter.makeArguments(prompt: "x", session: nil, configuration: withSystemPrompt)
        }
    }

    // MARK: - Output parsing

    @Test("Parses a recorded stream-json transcript")
    func parsesRecordedStream() async throws {
        let runner = RecordedProcessRunner(
            always: try .fixture(Fixture.url(Fixture.antigravityStream), chunkSize: 51)
        )
        let events = try await makeAdapter(runner).stream("x", configuration: configuration()).allEvents()

        let session = try #require(events.compactMap(\.sessionReference).first)
        #expect(session.sessionID == "b44e988e-f563-4c3a-9895-19b0169d23c5")
        #expect(session.cli == .antigravity)

        let deltas = events.compactMap { event -> String? in
            if case let .assistantTextDelta(text) = event { return text }
            return nil
        }
        #expect(deltas.joined().trimmingCharacters(in: .whitespacesAndNewlines) == "OK")

        let response = try #require(events.compactMap(\.response).first)
        #expect(response.text == "OK")
        #expect(response.stopReason == "SUCCESS")
        #expect(response.usage?.inputTokens == 15720)
        #expect(response.usage?.reasoningTokens == 180)
    }

    @Test("Parses the single-object result payload")
    func parsesResultPayload() throws {
        let payload = try JSONDecoder().decode(
            Antigravity.ResultPayload.self,
            from: try Fixture.data(Fixture.antigravityResult)
        )

        #expect(payload.conversationID == "b3e47bbd-4b48-4e4a-9b75-a17e4c7a7884")
        #expect(payload.status == "SUCCESS")
        #expect(payload.response == "OK\n")
        #expect(payload.makeUsageInfo()?.inputTokens == 15718)
    }

    @Test("Plain-text output is surfaced as diagnostics, not silently dropped")
    func handlesPlainTextOutput() async throws {
        // If a future release ignores --output-format, the caller still sees
        // something rather than an empty response with no explanation.
        let runner = RecordedProcessRunner(always: .output(try Fixture.text(Fixture.antigravityPrint)))
        let events = try await makeAdapter(runner).stream("x", configuration: configuration()).allEvents()

        #expect(events.contains { if case .diagnostic = $0 { return true } else { return false } })
    }

    // MARK: - Authentication

    /// `agy` has no auth-status command. `agy models` needs valid credentials,
    /// returns quickly, costs no tokens, and never opens a browser.
    @Test("Uses `agy models` as the credential probe")
    func probesWithModels() async {
        let runner = RecordedProcessRunner(matching: [
            "models": .output("gemini-3.7-flash-high\tGemini 3.7 Flash (High)\n"),
        ])
        let adapter = makeAdapter(runner)
        let status = await adapter.authenticationStatus()

        #expect(status.isAuthenticated)
        #expect(status.account?.method == .keychain)
        #expect(runner.lastInvocation?.arguments == ["models"])
    }

    @Test("A failed probe reports the login hand-off")
    func reportsSignedOut() async {
        let runner = RecordedProcessRunner(matching: ["models": .failure("Please sign in to continue")])
        let status = await makeAdapter(runner).authenticationStatus()

        #expect(status.isBlocked)
        #expect(status.loginCommand == "agy")
    }
}

@Suite("Antigravity structured output")
struct AntigravitySchemaTests {
    private func makeAdapter() -> Antigravity.Adapter {
        Antigravity.Adapter(
            runner: RecordedProcessRunner(always: .output("")),
            locator: FakeExecutableLocator()
        )
    }

    private func configuration(_ permissions: PermissionPolicy) -> RunConfiguration {
        var configuration = RunConfiguration(
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            permissions: permissions
        )
        configuration.outputSchema = .object(["a": .string()])
        return configuration
    }

    /// `agy` only fills `structured_output` in `json` mode; a schema run in
    /// `stream-json` comes back empty.
    @Test("A schema forces the buffered output format")
    func schemaForcesJSONFormat() throws {
        let arguments = try makeAdapter().makeArguments(
            prompt: "x",
            session: nil,
            configuration: configuration(.readOnly)
        )
        let formatIndex = try #require(arguments.firstIndex(of: "--output-format"))
        #expect(arguments[formatIndex + 1] == "json")
        #expect(arguments.contains("--json-schema"))
    }

    /// Plan mode plus a schema yields an empty response from the CLI, so the
    /// adapter refuses instead of returning nothing.
    @Test("Plan mode is refused for schema runs, with a reason")
    func refusesPlanModeWithSchema() {
        do {
            _ = try makeAdapter().makeArguments(
                prompt: "x",
                session: nil,
                configuration: configuration(.planOnly)
            )
            Issue.record("Expected a refusal")
        } catch let error as AgenticCLIError {
            guard case let .unsupportedPermissionPolicy(_, _, reason) = error else {
                Issue.record("Expected .unsupportedPermissionPolicy, got \(error)")
                return
            }
            #expect(reason.contains(".readOnly"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Read-only schema runs drop plan mode but keep the sandbox")
    func readOnlySchemaRunsUseSandbox() throws {
        let adapter = makeAdapter()
        let withSchema = try adapter.permissionArguments(for: .readOnly, withOutputSchema: true)
        let withoutSchema = try adapter.permissionArguments(for: .readOnly, withOutputSchema: false)

        #expect(withSchema == ["--sandbox"])
        #expect(withoutSchema == ["--mode", "plan", "--sandbox"])
    }

    @Test("Plan mode is still used when no schema is involved")
    func planModeUnaffectedWithoutSchema() throws {
        var configuration = RunConfiguration(
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            permissions: .planOnly
        )
        configuration.outputSchema = nil

        let arguments = try makeAdapter().makeArguments(
            prompt: "x",
            session: nil,
            configuration: configuration
        )
        #expect(arguments.contains("plan"))
        let formatIndex = try #require(arguments.firstIndex(of: "--output-format"))
        #expect(arguments[formatIndex + 1] == "stream-json")
    }
}
