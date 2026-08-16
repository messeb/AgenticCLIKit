import AgenticCLIKitTesting
import Foundation
import Testing

@testable import AgenticCLIKit

@Suite("AgenticCLIKit facade")
struct AgenticCLIKitFacadeTests {
    private let workingDirectory = URL(fileURLWithPath: "/tmp")

    /// A Claude adapter wired to recorded output: version probe, auth probe,
    /// and a run transcript.
    private func makeClaudeAdapter(
        authenticated: Bool = true,
        transcript: RecordedProcessRunner.Recording? = nil
    ) throws -> ClaudeCode.Adapter {
        let runTranscript = try transcript ?? .fixture(Fixture.url(Fixture.claudeStream))
        let runner = RecordedProcessRunner { invocation in
            let arguments = invocation.arguments
            if arguments.contains("--version") { return .output("2.1.224 (Claude Code)") }
            if arguments.first == "auth" {
                return authenticated
                    ? .output(#"{"loggedIn":true,"authMethod":"claude.ai","email":"me@example.com"}"#)
                    : .signedOut
            }
            return runTranscript
        }
        return ClaudeCode.Adapter(runner: runner, locator: FakeExecutableLocator())
    }

    private func configuration() -> RunConfiguration {
        RunConfiguration(workingDirectory: workingDirectory, permissions: .readOnly)
    }

    @Test("Registers the five shipped adapters by default")
    func registersDefaultAgents() {
        let kit = AgenticCLIKit()
        #expect(kit.agents.count == 5)
        #expect(kit[.claudeCode] != nil)
        #expect(kit[.codex] != nil)
        #expect(kit[.copilot] != nil)
        #expect(kit[.antigravity] != nil)
        #expect(kit[.vibe] != nil)
        #expect(kit["nonexistent"] == nil)
    }

    /// Selecting by capability rather than by name is what lets a host app add
    /// an adapter without touching its own picker logic.
    @Test("Selects agents by capability")
    func selectsByCapability() {
        // Every shipped adapter prompts and holds sessions; a registered CLI
        // that does neither must still be filtered out.
        let kit = AgenticCLIKit(agents: AgenticCLIKit.defaultAgents() + [StubAgent()])
        let conversational = kit.agents(supporting: [.prompting, .sessions])

        #expect(conversational.count == 5)
        #expect(!conversational.contains { $0.identifier == .stub })

        // Codex and Antigravity sandbox by filesystem scope rather than by tool
        // name, so they are not offered for a tool allowlist.
        let allowlisting = kit.agents(supporting: .toolAllowlist).map(\.identifier)
        #expect(allowlisting == [.claudeCode, .copilot, .vibe])
    }

    @Test("Health report covers every agent, in registration order")
    func buildsHealthReport() async throws {
        let kit = AgenticCLIKit(agents: [
            try makeClaudeAdapter(),
            StubAgent(),
        ])

        let report = await kit.healthReport()
        #expect(report.entries.map(\.cli) == [.claudeCode, .stub])
        #expect(report.entries.filter(\.isReady).count == report.entries.count)
        #expect(report.readyCLIs == [.claudeCode, .stub])
        #expect(report.entries.first?.version == "2.1.224")

        let summary = report.formattedSummary()
        #expect(summary.contains("Claude Code"))
        #expect(summary.contains("✓"))
    }

    @Test("A missing CLI is reported, not thrown, and carries the install hint")
    func reportsMissingCLI() async throws {
        let adapter = ClaudeCode.Adapter(
            runner: RecordedProcessRunner(always: .output("")),
            locator: FakeExecutableLocator(missing: ["claude"])
        )
        let report = await AgenticCLIKit(agents: [adapter]).healthReport()
        let entry = try #require(report.entries.first)

        #expect(!entry.isInstalled)
        #expect(!entry.isReady)
        #expect(entry.blocker?.contains("not installed") == true)
        #expect(entry.suggestedAction?.contains("npm install") == true)
    }

    @Test("An outdated CLI blocks readiness before auth is even probed")
    func blocksOnOutdatedVersion() async throws {
        let adapter = ClaudeCode.Adapter(
            runner: RecordedProcessRunner(always: .output("1.0.0 (Claude Code)")),
            locator: FakeExecutableLocator()
        )
        let readiness = await adapter.readiness()

        #expect(!readiness.isReady)
        guard case .unsupportedVersion = readiness.blocker else {
            Issue.record("Expected .unsupportedVersion, got \(String(describing: readiness.blocker))")
            return
        }
    }

    @Test("Runs check readiness first and refuse when signed out")
    func verifiesReadinessBeforeRunning() async throws {
        let kit = AgenticCLIKit(agents: [try makeClaudeAdapter(authenticated: false)])

        do {
            _ = try await kit.run("hello", using: .claudeCode, configuration: configuration())
            Issue.record("Expected a refusal")
        } catch let error as AgenticCLIError {
            guard case .notAuthenticated = error else {
                Issue.record("Expected .notAuthenticated, got \(error)")
                return
            }
        }
    }

    @Test("A successful run records its session")
    func recordsSessionAfterRun() async throws {
        let store = InMemorySessionStore()
        let kit = AgenticCLIKit(agents: [try makeClaudeAdapter()], sessionStore: store)

        let response = try await kit.run("hello", using: .claudeCode, configuration: configuration())
        #expect(response.text == "OK")

        let stored = try await store.sessions(for: .claudeCode)
        #expect(stored.map(\.sessionID) == ["941e8409-9752-49f6-97d0-2f08d0c93e01"])
    }

    /// Recording on `sessionStarted` rather than on completion means a run that
    /// is abandoned halfway still leaves a resumable conversation.
    @Test("Streaming records the session as soon as it is announced")
    func recordsSessionDuringStream() async throws {
        let store = InMemorySessionStore()
        let kit = AgenticCLIKit(agents: [try makeClaudeAdapter()], sessionStore: store)

        for try await event in kit.stream("hello", using: .claudeCode, configuration: configuration()) {
            if case .sessionStarted = event {
                // Already persisted at this point, mid-run.
                #expect(try await store.sessions(for: .claudeCode).count == 1)
                break
            }
        }
    }

    @Test("Unknown CLIs fail with a clear error")
    func rejectsUnknownCLI() async {
        let kit = AgenticCLIKit(agents: [])
        await #expect(throws: AgenticCLIError.self) {
            try await kit.run("hello", using: .claudeCode, configuration: configuration())
        }
    }

    @Test("Resuming a session-less CLI is refused by capability")
    func refusesResumeForSessionlessCLI() async {
        let kit = AgenticCLIKit(agents: [StubAgent(capabilities: .prompting)])
        let session = SessionReference(cli: .stub, sessionID: "x", workingDirectory: workingDirectory)

        do {
            _ = try await kit.resume(session, with: "more", configuration: configuration())
            Issue.record("Expected a refusal")
        } catch let error as AgenticCLIError {
            guard case let .unsupportedCapability(_, capability) = error else {
                Issue.record("Expected .unsupportedCapability, got \(error)")
                return
            }
            #expect(capability.contains(.sessions))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    /// The "continue where we left off" button: when the CLI has forgotten the
    /// stored session, the user should get a new conversation, not an error.
    @Test("continueOrStart falls back to a new run when the session is gone")
    func fallsBackWhenSessionIsGone() async throws {
        let store = InMemorySessionStore([
            SessionReference(cli: .claudeCode, sessionID: "forgotten", workingDirectory: workingDirectory),
        ])

        let transcript = try RecordedProcessRunner.Recording.fixture(Fixture.url(Fixture.claudeStream))
        let runner = RecordedProcessRunner { invocation in
            if invocation.arguments.contains("--version") { return .output("2.1.224 (Claude Code)") }
            if invocation.arguments.first == "auth" {
                return .output(#"{"loggedIn":true,"authMethod":"claude.ai"}"#)
            }
            // The resume attempt fails the way `claude` fails for a stale ID.
            if invocation.arguments.contains("--resume") {
                return .failure("No conversation found with session ID: forgotten")
            }
            return transcript
        }

        let kit = AgenticCLIKit(
            agents: [ClaudeCode.Adapter(runner: runner, locator: FakeExecutableLocator())],
            sessionStore: store
        )

        let response = try await kit.continueOrStart(
            "carry on",
            using: .claudeCode,
            configuration: configuration()
        )

        #expect(response.text == "OK")
        // The stale reference is dropped and replaced by the new session.
        let stored = try await store.sessions(for: .claudeCode)
        #expect(!stored.contains { $0.sessionID == "forgotten" })
        #expect(stored.count == 1)
    }

    @Test("Health reports encode for bug reports without leaking prompts")
    func healthReportIsCodable() async throws {
        let report = await AgenticCLIKit(agents: [try makeClaudeAdapter()]).healthReport()
        let encoded = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(HealthReport.self, from: encoded)

        #expect(decoded.entries.count == report.entries.count)
        #expect(decoded.entries.first?.cli == .claudeCode)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("hello"))
    }
}
