import AgenticCLIKitTesting
import Foundation
import Testing

@testable import AgenticCLIKit

@Suite("GitHub adapter")
struct GitHubAdapterTests {
    private func makeAdapter(_ runner: RecordedProcessRunner) -> GitHub.Adapter {
        GitHub.Adapter(runner: runner, locator: FakeExecutableLocator())
    }

    private let configuration = RunConfiguration(
        workingDirectory: URL(fileURLWithPath: "/tmp"),
        permissions: .readOnly
    )

    /// The reason `gh` is in the package: it keeps the capability system honest.
    @Test("Declares no prompting, sessions, or streaming")
    func declaresDegradedCapabilities() {
        let adapter = makeAdapter(RecordedProcessRunner(always: .output("")))
        #expect(!adapter.capabilities.contains(.prompting))
        #expect(!adapter.capabilities.contains(.sessions))
        #expect(!adapter.capabilities.contains(.streaming))
        #expect(adapter.capabilities.contains(.structuredOutput))
    }

    @Test("Prompting fails with a typed capability error rather than a crash")
    func refusesPrompting() async {
        let adapter = makeAdapter(RecordedProcessRunner(always: .output("")))
        do {
            _ = try await adapter.run("write me a PR description", configuration: configuration)
            Issue.record("Expected a refusal")
        } catch let error as AgenticCLIError {
            guard case let .unsupportedCapability(cli, capability) = error else {
                Issue.record("Expected .unsupportedCapability, got \(error)")
                return
            }
            #expect(cli == .github)
            #expect(capability.contains(.prompting))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Resuming fails with a sessions capability error")
    func refusesResume() async {
        let adapter = makeAdapter(RecordedProcessRunner(always: .output("")))
        let session = SessionReference(cli: .github, sessionID: "x", workingDirectory: URL(fileURLWithPath: "/tmp"))

        await #expect(throws: AgenticCLIError.self) {
            try await adapter.resume(session, with: "more", configuration: configuration)
        }
    }

    @Test("Runs explicit arguments and returns stdout")
    func executesArguments() async throws {
        let runner = RecordedProcessRunner(always: .output("https://github.com/example/repo/pull/7\n"))
        let response = try await makeAdapter(runner).execute(["pr", "create", "--fill"], configuration: configuration)

        #expect(response.text == "https://github.com/example/repo/pull/7")
        #expect(response.session == nil)
        #expect(runner.lastInvocation?.arguments == ["pr", "create", "--fill"])
    }

    @Test("Decodes typed JSON output")
    func decodesJSON() async throws {
        struct PullRequest: Decodable, Equatable {
            let number: Int
            let title: String
        }

        let runner = RecordedProcessRunner(always: .output(#"[{"number":7,"title":"Add adapter"}]"#))
        let pullRequests = try await makeAdapter(runner).decodeJSON(
            ["pr", "list", "--json", "number,title"],
            as: [PullRequest].self,
            configuration: configuration
        )

        #expect(pullRequests == [PullRequest(number: 7, title: "Add adapter")])
    }

    @Test("Undecodable output keeps the raw bytes for diagnosis")
    func reportsMalformedJSON() async {
        let runner = RecordedProcessRunner(always: .output("not json at all"))
        do {
            _ = try await makeAdapter(runner).decodeJSON(["pr", "list"], as: [String].self, configuration: configuration)
            Issue.record("Expected a failure")
        } catch let error as AgenticCLIError {
            guard case let .malformedOutput(_, raw) = error else {
                Issue.record("Expected .malformedOutput, got \(error)")
                return
            }
            #expect(raw.map { String(decoding: $0, as: UTF8.self) } == "not json at all")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    /// `gh auth status` writes its report to stderr, which is easy to miss.
    @Test("Reads the account out of the stderr report")
    func parsesAuthStatus() async {
        let report = """
        github.com
          ✓ Logged in to github.com account octocat (keyring)
          - Active account: true
          - Token scopes: 'gist', 'read:org', 'repo'
        """
        let runner = RecordedProcessRunner(matching: [
            "auth status": RecordedProcessRunner.Recording(standardError: Data(report.utf8)),
        ])
        let status = await makeAdapter(runner).authenticationStatus()

        #expect(status.isAuthenticated)
        #expect(status.account?.identifier == "octocat")
        #expect(status.account?.organization == "github.com")
    }

    @Test("A signed-out CLI reports `gh auth login`")
    func parsesSignedOut() async {
        let runner = RecordedProcessRunner(matching: [
            "auth status": .failure("You are not logged into any GitHub hosts. To log in, run: gh auth login"),
        ])
        let status = await makeAdapter(runner).authenticationStatus()

        #expect(status.isBlocked)
        #expect(status.loginCommand == "gh auth login")
    }

    @Test("Command failures map to typed errors")
    func mapsFailures() async {
        let runner = RecordedProcessRunner(always: .failure("gh: Bad credentials", exitCode: 1))
        do {
            _ = try await makeAdapter(runner).execute(["repo", "view"], configuration: configuration)
            Issue.record("Expected a failure")
        } catch let error as AgenticCLIError {
            guard case .notAuthenticated = error else {
                Issue.record("Expected .notAuthenticated, got \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
