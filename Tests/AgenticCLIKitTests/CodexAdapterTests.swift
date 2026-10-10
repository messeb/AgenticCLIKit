import AgenticCLIKitTesting
import Foundation
import Testing

@testable import AgenticCLIKit

@Suite("Codex adapter")
struct CodexAdapterTests {
    private func makeAdapter(_ runner: RecordedProcessRunner) -> Codex.Adapter {
        Codex.Adapter(runner: runner, locator: FakeExecutableLocator())
    }

    private let workingDirectory = URL(fileURLWithPath: "/tmp/agentickit-tests")

    private func configuration(_ permissions: PermissionPolicy = .readOnly) -> RunConfiguration {
        RunConfiguration(workingDirectory: workingDirectory, permissions: permissions)
    }

    // MARK: - Argument construction

    @Test("A new run uses `codex exec --json` with the prompt last")
    func buildsExecArguments() throws {
        let adapter = makeAdapter(RecordedProcessRunner(always: .output("")))
        let arguments = try adapter.makeArguments(
            prompt: "hello",
            session: nil,
            configuration: configuration()
        )

        #expect(arguments.first == "exec")
        #expect(arguments.contains("--json"))
        #expect(arguments.contains("--sandbox"))
        #expect(arguments.contains("read-only"))
        #expect(arguments.last == "hello")
    }

    /// `codex exec resume` rejects `--sandbox` outright, and it parses
    /// `<SESSION_ID> <PROMPT>` positionally only after its flags. Both were
    /// found by running the real CLI, not by reading its help text.
    @Test("Resume uses the config override for sandboxing and ordered positionals")
    func buildsResumeArguments() throws {
        let adapter = makeAdapter(RecordedProcessRunner(always: .output("")))
        let session = SessionReference(
            cli: .codex,
            sessionID: "01a006a4-1352-7bb1-bf85-913821a88af0",
            workingDirectory: workingDirectory
        )
        let arguments = try adapter.makeArguments(
            prompt: "and now?",
            session: session,
            configuration: configuration()
        )

        #expect(arguments.starts(with: ["exec", "resume"]))
        #expect(!arguments.contains("--sandbox"))
        #expect(arguments.contains("-c"))
        #expect(arguments.contains(#"sandbox_mode="read-only""#))

        // Positionals last, session before prompt.
        let sessionIndex = try #require(arguments.firstIndex(of: session.sessionID))
        let promptIndex = try #require(arguments.firstIndex(of: "and now?"))
        #expect(sessionIndex < promptIndex)
        #expect(promptIndex == arguments.count - 1)
    }

    @Test(
        "Permission policies map onto sandbox modes",
        arguments: [
            (PermissionPolicy.planOnly, "read-only"),
            (.readOnly, "read-only"),
            (.acceptingEdits, "workspace-write"),
        ]
    )
    func mapsSandboxModes(policy: PermissionPolicy, expected: String) throws {
        let adapter = makeAdapter(RecordedProcessRunner(always: .output("")))
        #expect(try adapter.sandboxMode(for: policy)?.rawValue == expected)
    }

    @Test("Bypassing all permissions drops the sandbox entirely")
    func mapsBypass() throws {
        let adapter = makeAdapter(RecordedProcessRunner(always: .output("")))
        #expect(try adapter.sandboxMode(for: .unsafeBypassAll) == nil)

        let arguments = try adapter.makeArguments(
            prompt: "x",
            session: nil,
            configuration: configuration(.unsafeBypassAll)
        )
        #expect(arguments.contains("--dangerously-bypass-approvals-and-sandbox"))
    }

    /// Codex sandboxes by filesystem scope, not by tool name. Silently
    /// upgrading a tool allowlist to `workspace-write` would hand the agent
    /// more access than the caller asked for.
    @Test("A tool allowlist is refused rather than widened")
    func refusesToolAllowlist() {
        let adapter = makeAdapter(RecordedProcessRunner(always: .output("")))
        #expect(!adapter.capabilities.contains(.toolAllowlist))

        do {
            _ = try adapter.sandboxMode(for: .allowingTools(["Read"]))
            Issue.record("Expected a refusal")
        } catch let error as AgenticCLIError {
            guard case .unsupportedPermissionPolicy = error else {
                Issue.record("Expected .unsupportedPermissionPolicy, got \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Resume has no --add-dir, so extra directories are refused there")
    func refusesAdditionalDirectoriesOnResume() throws {
        let adapter = makeAdapter(RecordedProcessRunner(always: .output("")))
        var configuration = configuration()
        configuration.additionalDirectories = [URL(fileURLWithPath: "/extra")]

        // Allowed on a fresh run…
        let fresh = try adapter.makeArguments(prompt: "x", session: nil, configuration: configuration)
        #expect(fresh.contains("--add-dir"))

        // …but not on resume.
        let session = SessionReference(cli: .codex, sessionID: "s", workingDirectory: workingDirectory)
        #expect(throws: AgenticCLIError.self) {
            try adapter.makeArguments(prompt: "x", session: session, configuration: configuration)
        }
    }

    @Test("Non-git directories are allowed by default")
    func skipsGitRepositoryCheck() throws {
        let adapter = makeAdapter(RecordedProcessRunner(always: .output("")))
        let arguments = try adapter.makeArguments(prompt: "x", session: nil, configuration: configuration())
        #expect(arguments.contains("--skip-git-repo-check"))

        let strict = Codex.Adapter(
            runner: RecordedProcessRunner(always: .output("")),
            locator: FakeExecutableLocator(),
            allowsNonGitDirectories: false
        )
        let strictArguments = try strict.makeArguments(prompt: "x", session: nil, configuration: configuration())
        #expect(!strictArguments.contains("--skip-git-repo-check"))
    }

    /// Leaving stdin open makes `codex exec` block reading it — the failure
    /// mode is a host app that hangs with no output.
    @Test("stdin is always closed for codex runs")
    func closesStandardInput() async throws {
        let runner = RecordedProcessRunner(always: try .fixture(Fixture.url(Fixture.codexStream)))
        var configuration = configuration()
        configuration.standardInput = Data("should not be sent".utf8)

        _ = try await makeAdapter(runner).run("x", configuration: configuration)
        #expect(runner.lastInvocation?.standardInput == nil)
    }

    // MARK: - Output parsing

    @Test("Parses a recorded JSONL transcript")
    func parsesRecordedStream() async throws {
        let runner = RecordedProcessRunner(always: try .fixture(Fixture.url(Fixture.codexStream), chunkSize: 23))
        let events = try await makeAdapter(runner).stream("x", configuration: configuration()).allEvents()

        let session = try #require(events.compactMap(\.sessionReference).first)
        #expect(session.sessionID == "01a006a4-1352-7bb1-bf85-913821a88af0")
        #expect(session.cli == .codex)

        // Codex reports completed items, never token deltas.
        #expect(events.compactMap(\.text) == ["OK"])
        #expect(!events.contains { if case .assistantTextDelta = $0 { return true } else { return false } })

        let response = try #require(events.compactMap(\.response).first)
        #expect(response.text == "OK")
        #expect(response.usage?.inputTokens == 12401)
        #expect(response.usage?.cachedInputTokens == 4992)
        #expect(response.usage?.reasoningTokens == 11)
        #expect(!response.isError)
    }

    @Test("Resuming a recorded session keeps the original session ID")
    func parsesRecordedResume() async throws {
        let runner = RecordedProcessRunner(always: try .fixture(Fixture.url(Fixture.codexResume)))
        let session = SessionReference(
            cli: .codex,
            sessionID: "01a006a4-1352-7bb1-bf85-913821a88af0",
            workingDirectory: workingDirectory
        )
        let response = try await makeAdapter(runner)
            .resume(session, with: "Reply with exactly: RESUMED", configuration: configuration())

        #expect(response.text == "RESUMED")
        #expect(response.session?.sessionID == session.sessionID)
    }

    // MARK: - Usage on resume

    private let rolloutThreadID = "01a12536-76a1-7ac3-b2dc-a1066634f67c"

    /// A `$CODEX_HOME` whose rollout log holds the thread as it stood before
    /// the resume, as `codex` lays it out.
    private func makeHomeWithRollout() throws -> (home: URL, rollout: URL) {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codex-home-\(UUID().uuidString)", isDirectory: true)
        let day = home.appendingPathComponent("sessions/2026/10/10", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let rollout = day.appendingPathComponent("rollout-2026-10-10T11-48-08-\(rolloutThreadID).jsonl")
        try FileManager.default.copyItem(at: Fixture.url(Fixture.codexRolloutBeforeResume), to: rollout)
        return (home, rollout)
    }

    /// `codex` reports a resumed turn's usage as the thread's running total, so a caller summing turns — or just reading one — would bill the
    /// whole conversation again. The turn is the change in the rollout's total.
    @Test("A resumed turn reports its own usage, not the thread's running total")
    func resumedUsageIsTheTurnOnly() async throws {
        let (home, rollout) = try makeHomeWithRollout()
        let resumedTurn = try Fixture.data(Fixture.codexRolloutResumedTurn)
        let stream = try Fixture.data(Fixture.codexResumeCumulative)
        // The CLI appends the turn's totals to its rollout as it runs.
        let runner = RecordedProcessRunner { _ in
            if let handle = try? FileHandle(forWritingTo: rollout) {
                handle.seekToEndOfFile()
                handle.write(resumedTurn)
                try? handle.close()
            }
            return RecordedProcessRunner.Recording(standardOutput: stream)
        }
        let adapter = Codex.Adapter(runner: runner, locator: FakeExecutableLocator(), home: home)
        let session = SessionReference(cli: .codex, sessionID: rolloutThreadID, workingDirectory: workingDirectory)

        let events = try await adapter
            .stream(resuming: session, prompt: "Reply with exactly: OK3", configuration: configuration())
            .allEvents()

        let response = try #require(events.compactMap(\.response).first)
        #expect(response.text == "OK3")
        let usage = try #require(response.usage)
        #expect(usage.inputTokens == 50623 - 33731)
        #expect(usage.cachedInputTokens == 46464 - 29824)
        #expect(usage.outputTokens == 17 - 11)

        let completed = events.compactMap { event -> UsageInfo?? in
            if case let .turnCompleted(usage) = event { return usage }
            return nil
        }
        #expect(completed.count == 1)
        #expect(completed.first??.outputTokens == 6)
    }

    /// Without a rollout that matches, there is no baseline to trust: the
    /// reported figure passes through rather than being guessed at. (This
    /// recording's thread is not the one in the rollout.)
    @Test("Usage that does not match the rollout's total is passed through")
    func unmatchedUsageIsUntouched() async throws {
        let (home, _) = try makeHomeWithRollout()
        let runner = RecordedProcessRunner(always: try .fixture(Fixture.url(Fixture.codexResume)))
        let adapter = Codex.Adapter(runner: runner, locator: FakeExecutableLocator(), home: home)
        let session = SessionReference(cli: .codex, sessionID: rolloutThreadID, workingDirectory: workingDirectory)

        let response = try await adapter
            .resume(session, with: "Reply with exactly: RESUMED", configuration: configuration())
        #expect(response.usage?.inputTokens == 24820)
        #expect(response.usage?.outputTokens == 35)
    }

    @Test("Shell commands surface as tool events")
    func mapsCommandExecution() async throws {
        let transcript = """
        {"type":"thread.started","thread_id":"t1"}
        {"type":"item.started","item":{"id":"i1","type":"command_execution","command":"ls -la"}}
        {"type":"item.completed","item":{"id":"i1","type":"command_execution","command":"ls -la","aggregated_output":"total 0","exit_code":0}}
        {"type":"item.completed","item":{"id":"i2","type":"agent_message","text":"Listed."}}
        {"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":2}}

        """
        let runner = RecordedProcessRunner(always: .output(transcript))
        let events = try await makeAdapter(runner).stream("x", configuration: configuration()).allEvents()

        let invocation = try #require(events.compactMap { event -> ToolInvocation? in
            if case let .toolUseRequested(tool) = event { return tool }
            return nil
        }.first)
        #expect(invocation.name == "shell")
        #expect(invocation.summary == "ls -la")

        let outcome = try #require(events.compactMap { event -> ToolOutcome? in
            if case let .toolResult(outcome) = event { return outcome }
            return nil
        }.first)
        #expect(outcome.isError == false)
        #expect(outcome.output.map { String(decoding: $0, as: UTF8.self) } == "total 0")
    }

    @Test("A failed turn becomes a typed error")
    func mapsTurnFailure() async {
        let transcript = """
        {"type":"thread.started","thread_id":"t1"}
        {"type":"turn.failed","error":{"message":"Not logged in. Please run `codex login`."}}

        """
        do {
            _ = try await makeAdapter(RecordedProcessRunner(always: .output(transcript)))
                .run("x", configuration: configuration())
            Issue.record("Expected a failure")
        } catch let error as AgenticCLIError {
            guard case let .notAuthenticated(cli, command) = error else {
                Issue.record("Expected .notAuthenticated, got \(error)")
                return
            }
            #expect(cli == .codex)
            #expect(command == "codex login")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    // MARK: - Authentication

    @Test("Recognises the real `codex login status` output")
    func parsesLoginStatus() async {
        let runner = RecordedProcessRunner(matching: ["login status": .output("Logged in using ChatGPT\n")])
        let status = await makeAdapter(runner).authenticationStatus()

        #expect(status.isAuthenticated)
        #expect(status.account?.method == .subscription)
    }

    @Test("A signed-out CLI is reported as blocked")
    func parsesSignedOut() async {
        let runner = RecordedProcessRunner(matching: [
            "login status": .failure("Not logged in"),
        ])
        let status = await makeAdapter(runner).authenticationStatus()

        #expect(status.isBlocked)
        #expect(status.loginCommand == "codex login")
    }
}
