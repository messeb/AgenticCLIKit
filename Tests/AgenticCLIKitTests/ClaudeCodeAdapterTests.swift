import AgenticCLIKitTesting
import Foundation
import Testing

@testable import AgenticCLIKit

@Suite("ClaudeCode adapter")
struct ClaudeCodeAdapterTests {
    private func makeAdapter(_ runner: RecordedProcessRunner) -> ClaudeCode.Adapter {
        ClaudeCode.Adapter(runner: runner, locator: FakeExecutableLocator())
    }

    private let workingDirectory = URL(fileURLWithPath: "/tmp/agentickit-tests")

    // MARK: - Argument construction

    @Test("Print mode asks for streaming JSON, which needs --verbose")
    func buildsPrintArguments() throws {
        let adapter = makeAdapter(RecordedProcessRunner(always: .output("")))
        let arguments = try adapter.makeArguments(
            prompt: "hello",
            session: nil,
            configuration: RunConfiguration(workingDirectory: workingDirectory, permissions: .planOnly)
        )

        #expect(arguments.starts(with: ["--print", "hello"]))
        #expect(arguments.contains("--output-format"))
        #expect(arguments.contains("stream-json"))
        // `claude` rejects stream-json in print mode without --verbose.
        #expect(arguments.contains("--verbose"))
    }

    @Test(
        "Each permission policy maps to distinct flags",
        arguments: [
            (PermissionPolicy.planOnly, ["--permission-mode", "plan"]),
            (.acceptingEdits, ["--permission-mode", "acceptEdits"]),
            (.unsafeBypassAll, ["--dangerously-skip-permissions"]),
        ]
    )
    func mapsPermissionPolicies(policy: PermissionPolicy, expected: [String]) throws {
        let adapter = makeAdapter(RecordedProcessRunner(always: .output("")))
        let arguments = try adapter.permissionArguments(for: policy)
        #expect(arguments == expected)
    }

    @Test("Read-only denies the mutating tools explicitly")
    func readOnlyDeniesMutatingTools() throws {
        let adapter = makeAdapter(RecordedProcessRunner(always: .output("")))
        let arguments = try adapter.permissionArguments(for: .readOnly)

        #expect(arguments.contains("manual"))
        #expect(arguments.contains("Read"))
        #expect(arguments.contains("--disallowedTools"))
        for tool in ClaudeCode.mutatingTools {
            #expect(arguments.contains(tool))
        }
        #expect(!arguments.contains("--dangerously-skip-permissions"))
    }

    @Test("Tool allowlists pass through both lists")
    func mapsToolAllowlist() throws {
        let adapter = makeAdapter(RecordedProcessRunner(always: .output("")))
        let arguments = try adapter.permissionArguments(
            for: .allowingTools(allowed: ["Read", "Bash(git *)"], denied: ["Write"])
        )
        #expect(arguments.contains("Bash(git *)"))
        #expect(arguments.contains("--disallowedTools"))
        #expect(arguments.contains("Write"))
    }

    /// `claude` 2.1.224 has no `--max-turns`. Passing it would fail deep inside
    /// the CLI with an opaque message, so the adapter refuses up front.
    @Test("Rejects maximumTurns rather than passing an unknown flag")
    func rejectsUnsupportedTurnLimit() {
        let adapter = makeAdapter(RecordedProcessRunner(always: .output("")))
        var configuration = RunConfiguration(workingDirectory: workingDirectory, permissions: .planOnly)
        configuration.maximumTurns = 3

        #expect(!adapter.capabilities.contains(.turnLimits))
        #expect(throws: AgenticCLIError.self) {
            try adapter.makeArguments(prompt: "hi", session: nil, configuration: configuration)
        }
    }

    @Test("Resume passes the session ID and keeps cross-directory support")
    func buildsResumeArguments() throws {
        let adapter = makeAdapter(RecordedProcessRunner(always: .output("")))
        let session = SessionReference(
            cli: .claudeCode,
            sessionID: "abc-123",
            workingDirectory: URL(fileURLWithPath: "/some/other/repo")
        )
        let arguments = try adapter.makeArguments(
            prompt: "and now?",
            session: session,
            // Deliberately a different directory: claude resumes across them.
            configuration: RunConfiguration(workingDirectory: workingDirectory, permissions: .readOnly)
        )

        #expect(arguments.contains("--resume"))
        #expect(arguments.contains("abc-123"))
    }

    @Test("Optional configuration only appears when set")
    func includesOptionalFlagsOnlyWhenSet() throws {
        let adapter = makeAdapter(RecordedProcessRunner(always: .output("")))
        var configuration = RunConfiguration(workingDirectory: workingDirectory, permissions: .readOnly)

        let bare = try adapter.makeArguments(prompt: "p", session: nil, configuration: configuration)
        #expect(!bare.contains("--model"))
        #expect(!bare.contains("--no-session-persistence"))
        #expect(!bare.contains("--add-dir"))

        configuration.model = "opus"
        configuration.persistsSession = false
        configuration.additionalDirectories = [URL(fileURLWithPath: "/extra")]
        configuration.systemPromptAppendix = "Be terse."
        configuration.extraArguments = ["--custom-flag"]

        let full = try adapter.makeArguments(prompt: "p", session: nil, configuration: configuration)
        #expect(full.contains("opus"))
        #expect(full.contains("--no-session-persistence"))
        #expect(full.contains("/extra"))
        #expect(full.contains("Be terse."))
    }

    // MARK: - Output parsing

    @Test("Parses a recorded stream-json transcript end to end")
    func parsesRecordedStream() async throws {
        let runner = RecordedProcessRunner(always: try .fixture(Fixture.url(Fixture.claudeStream), chunkSize: 37))
        let adapter = makeAdapter(runner)

        let events = try await adapter
            .stream("Reply with exactly: OK", configuration: .testing(workingDirectory: workingDirectory))
            .allEvents()

        let session = events.compactMap(\.sessionReference).first
        #expect(session?.sessionID == "941e8409-9752-49f6-97d0-2f08d0c93e01")
        #expect(session?.cli == .claudeCode)

        // The recorded run streamed "O" then "K".
        let deltas = events.compactMap { event -> String? in
            if case let .assistantTextDelta(text) = event { return text }
            return nil
        }
        #expect(deltas == ["O", "K"])

        let response = try #require(events.compactMap(\.response).first)
        #expect(response.text == "OK")
        #expect(response.session?.sessionID == "941e8409-9752-49f6-97d0-2f08d0c93e01")
        #expect(response.usage?.costUSD != nil)
        #expect(response.stopReason == "end_turn")
        #expect(!response.isError)

        // The hook and rate-limit events this CLI emits have no typed mapping;
        // they must survive as raw rather than being dropped.
        #expect(events.contains { if case .raw = $0 { return true } else { return false } })
    }

    @Test("Chunk boundaries do not change the parse")
    func chunkingDoesNotAffectResult() async throws {
        var texts: [String] = []
        for chunkSize in [1, 7, 512, 65_536] {
            let runner = RecordedProcessRunner(
                always: try .fixture(Fixture.url(Fixture.claudeStream), chunkSize: chunkSize)
            )
            let response = try await makeAdapter(runner)
                .run("x", configuration: .testing(workingDirectory: workingDirectory))
            texts.append(response.text)
        }
        #expect(texts == ["OK", "OK", "OK", "OK"])
    }

    @Test("Streaming and buffered runs agree")
    func streamAndRunAgree() async throws {
        let makeRunner = { RecordedProcessRunner(always: try .fixture(Fixture.url(Fixture.claudeStream))) }
        let streamed = try await makeAdapter(try makeRunner())
            .stream("x", configuration: .testing(workingDirectory: workingDirectory))
            .collected()
        let buffered = try await makeAdapter(try makeRunner())
            .run("x", configuration: .testing(workingDirectory: workingDirectory))

        #expect(streamed.text == buffered.text)
        #expect(streamed.session?.sessionID == buffered.session?.sessionID)
        #expect(streamed.usage?.costUSD == buffered.usage?.costUSD)
    }

    @Test("Parses the single-object result payload")
    func parsesResultPayload() throws {
        let payload = try JSONDecoder().decode(
            ClaudeCode.ResultPayload.self,
            from: try Fixture.data(Fixture.claudeResult)
        )

        #expect(payload.sessionID == "d7b80784-e16a-4cf1-9143-12d5c09bee8e")
        #expect(payload.result == "OK")
        #expect(payload.isError == false)
        #expect(payload.subtype == "success")

        let usage = try #require(payload.makeUsageInfo())
        #expect(usage.inputTokens == 2)
        #expect(usage.outputTokens == 4)
        #expect(usage.cachedInputTokens == 16153)
        #expect(usage.costUSD == 0.1793865)
        #expect(usage.model == "claude-opus-5[1m]")
    }

    // MARK: - Authentication

    @Test("Reads the account out of `claude auth status`")
    func parsesAuthenticatedStatus() async throws {
        let runner = RecordedProcessRunner(matching: [
            "auth status": .output(#"""
            {"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty",
             "email":"person@example.com","orgName":"Example Org","subscriptionType":"max"}
            """#),
        ])
        let status = await makeAdapter(runner).authenticationStatus()

        #expect(status.isAuthenticated)
        #expect(status.account?.identifier == "person@example.com")
        #expect(status.account?.method == .subscription)
        #expect(status.account?.plan == "max")
        #expect(!status.isBlocked)
    }

    @Test("A signed-out CLI reports the command that fixes it")
    func parsesSignedOutStatus() async throws {
        let runner = RecordedProcessRunner(matching: [
            "auth status": .signedOut,
        ])
        let status = await makeAdapter(runner).authenticationStatus()

        #expect(!status.isAuthenticated)
        #expect(status.isBlocked)
        #expect(status.loginCommand == "claude auth login")
    }

    @Test("An unreadable probe is reported as unknown, not as signed out")
    func distinguishesUnreadableProbe() async throws {
        // A future CLI that stops printing JSON must not be mistaken for a
        // signed-out one — that would send users to a pointless login flow.
        let runner = RecordedProcessRunner(matching: ["auth status": .output("all good!")])
        let status = await makeAdapter(runner).authenticationStatus()

        if case .undetectable = status {} else {
            Issue.record("Expected .undetectable, got \(status)")
        }
        #expect(!status.isBlocked)
    }

    // MARK: - Failure mapping

    @Test(
        "Maps stderr prose onto typed errors",
        arguments: [
            "Invalid API key · Please run /login",
            "OAuth token has expired",
        ]
    )
    func mapsAuthenticationFailures(message: String) async {
        let runner = RecordedProcessRunner(always: .failure(message))
        let adapter = makeAdapter(runner)

        await #expect(throws: AgenticCLIError.self) {
            try await adapter.run("x", configuration: .testing(workingDirectory: workingDirectory))
        }

        do {
            _ = try await adapter.run("x", configuration: .testing(workingDirectory: workingDirectory))
        } catch let error as AgenticCLIError {
            guard case .notAuthenticated = error else {
                Issue.record("Expected .notAuthenticated, got \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("An unknown failure keeps its exit code and stderr")
    func fallsBackToProcessFailed() async {
        let runner = RecordedProcessRunner(always: .failure("something entirely new went wrong", exitCode: 42))
        do {
            _ = try await makeAdapter(runner).run("x", configuration: .testing(workingDirectory: workingDirectory))
            Issue.record("Expected a failure")
        } catch let error as AgenticCLIError {
            guard case let .processFailed(cli, exitCode, standardError) = error else {
                Issue.record("Expected .processFailed, got \(error)")
                return
            }
            #expect(cli == .claudeCode)
            #expect(exitCode == 42)
            #expect(standardError.contains("entirely new"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Hitting the turn limit is its own error, carrying the partial text")
    func mapsTurnLimit() async {
        let line = #"{"type":"result","subtype":"error_max_turns","is_error":true,"session_id":"s1","result":"partial work"}"#
        let runner = RecordedProcessRunner(always: .output(line + "\n"))

        do {
            _ = try await makeAdapter(runner).run("x", configuration: .testing(workingDirectory: workingDirectory))
            Issue.record("Expected a failure")
        } catch let error as AgenticCLIError {
            guard case let .turnLimitReached(_, partialText) = error else {
                Issue.record("Expected .turnLimitReached, got \(error)")
                return
            }
            #expect(partialText == "partial work")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}

extension RecordedProcessRunner.Recording {
    static let signedOut = RecordedProcessRunner.Recording(
        standardOutput: Data(#"{"loggedIn":false}"#.utf8),
        exitCode: 1
    )
}
