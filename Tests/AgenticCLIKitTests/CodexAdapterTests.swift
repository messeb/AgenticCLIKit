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
