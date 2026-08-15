#if canImport(Darwin)
import Darwin
#endif
import Foundation
import Testing

@testable import AgenticCLIKit

/// These spawn real processes on purpose. Process management is the part of
/// this package that cannot be verified with a fake — the failure modes worth
/// testing (a child that ignores SIGTERM, a grandchild that outlives its
/// parent, a pipe that fills) only exist against the real kernel.
@Suite("SubprocessRunner", .timeLimit(.minutes(1)))
struct SubprocessRunnerTests {
    private let shell = URL(fileURLWithPath: "/bin/sh")
    private let runner = SubprocessRunner(cli: "test")

    private func invocation(
        _ script: String,
        timeout: Duration = .seconds(20),
        standardInput: Data? = nil,
        maximumOutputBytes: Int = 32 * 1024 * 1024
    ) -> ProcessInvocation {
        ProcessInvocation(
            executableURL: shell,
            arguments: ["-c", script],
            environment: ["PATH": "/usr/bin:/bin"],
            standardInput: standardInput,
            timeout: timeout,
            maximumOutputBytes: maximumOutputBytes
        )
    }

    @Test("Captures stdout and stderr separately")
    func capturesStreams() async throws {
        let result = try await runner.run(invocation("echo out; echo err >&2"))

        #expect(result.standardOutputText == "out\n")
        #expect(result.standardErrorText == "err")
        #expect(result.exit.isSuccess)
    }

    @Test("Propagates the exit code")
    func propagatesExitCode() async throws {
        let result = try await runner.run(invocation("exit 7"))

        #expect(result.exit.code == 7)
        #expect(!result.exit.isSuccess)
    }

    @Test("Writes stdin when provided")
    func writesStandardInput() async throws {
        let result = try await runner.run(invocation("cat", standardInput: Data("piped\n".utf8)))
        #expect(result.standardOutputText == "piped\n")
    }

    /// The single most common way an embedded CLI hangs a host app: stdin stays
    /// open, the CLI waits for input that never comes.
    @Test("Closes stdin when none is provided, so readers do not block")
    func closesStandardInputByDefault() async throws {
        let result = try await runner.run(invocation("cat", timeout: .seconds(5)))

        #expect(result.standardOutputText.isEmpty)
        #expect(result.exit.isSuccess)
    }

    @Test("Does not truncate large output")
    func handlesLargeOutput() async throws {
        // ~2 MB, far past a pipe buffer, forcing many partial reads.
        let result = try await runner.run(invocation("for i in $(seq 1 40000); do echo 0123456789012345678901234567890123456789012345678; done"))

        // 40,000 lines of 49 characters plus newlines.
        #expect(result.standardOutput.count == 2_000_000)
        #expect(result.standardOutputText.hasSuffix("\n"))
        #expect(result.exit.isSuccess)
    }

    @Test("Enforces the output cap")
    func enforcesOutputLimit() async {
        do {
            _ = try await runner.run(invocation(
                "while true; do echo spam; done",
                timeout: .seconds(20),
                maximumOutputBytes: 32 * 1024
            ))
            Issue.record("Expected an output-limit failure")
        } catch let error as AgenticCLIError {
            guard case .outputLimitExceeded = error else {
                Issue.record("Expected .outputLimitExceeded, got \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Times out and reports it as such")
    func timesOut() async {
        let clock = ContinuousClock()
        let started = clock.now
        do {
            _ = try await runner.run(invocation("sleep 30", timeout: .milliseconds(400)))
            Issue.record("Expected a timeout")
        } catch let error as AgenticCLIError {
            guard case .timedOut = error else {
                Issue.record("Expected .timedOut, got \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        // The timeout must actually cut the run short, not merely report late.
        #expect((clock.now - started) < .seconds(10))
    }

    @Test("A timeout kills the whole process tree, not just the shell")
    func timeoutKillsDescendants() async throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentickit-pid-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pidFile) }

        // The shell spawns a grandchild and then blocks. Signalling only the
        // direct child would leave `sleep 45` running.
        _ = try? await runner.run(invocation(
            "sleep 45 & echo $! > \(pidFile.path); sleep 45",
            timeout: .milliseconds(500)
        ))

        let recorded = try String(contentsOf: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let grandchild = try #require(pid_t(recorded))

        // Allow the SIGTERM/SIGKILL escalation to complete.
        try await Task.sleep(for: .seconds(7))
        #expect(!ProcessTree.isAlive(grandchild), "Grandchild \(grandchild) survived the timeout")
    }

    @Test("Cancelling the task kills the child")
    func cancellationKillsChild() async throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentickit-cancel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pidFile) }

        let invocation = invocation("echo $$ > \(pidFile.path); sleep 45", timeout: .seconds(60))
        let runner = self.runner
        let task = Task { try await runner.run(invocation) }

        // Wait for the child to record its own PID.
        var recorded: pid_t?
        for _ in 0..<100 {
            if let text = try? String(contentsOf: pidFile, encoding: .utf8),
               let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                recorded = pid
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let childPID = try #require(recorded)

        task.cancel()
        _ = try? await task.value

        try await Task.sleep(for: .seconds(7))
        #expect(!ProcessTree.isAlive(childPID), "Child \(childPID) survived cancellation")
    }

    @Test("Abandoning a stream mid-iteration still kills the child")
    func abandonedStreamKillsChild() async throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentickit-abandon-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pidFile) }

        // A host app that stops consuming a stream — the user closed the window —
        // must not leak an agent process. Releasing the stream is what signals
        // abandonment, so the stream is scoped to a nested call here rather
        // than left alive in the test's own scope.
        func consumeFirstChunkThenAbandon() async throws {
            let stream = runner.stream(invocation(
                "echo $$ > \(pidFile.path); echo hello; sleep 45",
                timeout: .seconds(60)
            ))
            for try await event in stream {
                if case .standardOutput = event { break }
            }
        }
        try await consumeFirstChunkThenAbandon()

        let recorded = try String(contentsOf: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let childPID = try #require(pid_t(recorded))

        try await Task.sleep(for: .seconds(7))
        #expect(!ProcessTree.isAlive(childPID), "Child \(childPID) survived stream abandonment")
    }

    @Test("Passes only the environment it was given")
    func isolatesEnvironment() async throws {
        var invocation = invocation("env")
        invocation.environment = EnvironmentPolicy.base.resolved(
            againstHostEnvironment: [
                "PATH": "/usr/bin:/bin",
                "HOME": "/tmp",
                "MY_APP_SECRET": "do-not-leak",
            ]
        )

        let result = try await runner.run(invocation)
        #expect(!result.standardOutputText.contains("MY_APP_SECRET"))
        #expect(result.standardOutputText.contains("HOME=/tmp"))
    }

    @Test("Reports a missing executable rather than crashing")
    func reportsMissingExecutable() async {
        let invocation = ProcessInvocation(
            executableURL: URL(fileURLWithPath: "/definitely/not/here"),
            timeout: .seconds(5)
        )
        do {
            _ = try await runner.run(invocation)
            Issue.record("Expected a launch failure")
        } catch let error as AgenticCLIError {
            guard case .launchFailed = error else {
                Issue.record("Expected .launchFailed, got \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Reports a missing working directory")
    func reportsMissingWorkingDirectory() async {
        var invocation = invocation("pwd")
        invocation.workingDirectory = URL(fileURLWithPath: "/definitely/not/a/directory")

        do {
            _ = try await runner.run(invocation)
            Issue.record("Expected a working-directory failure")
        } catch let error as AgenticCLIError {
            guard case .invalidWorkingDirectory = error else {
                Issue.record("Expected .invalidWorkingDirectory, got \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Streams output incrementally rather than only at exit")
    func streamsIncrementally() async throws {
        let clock = ContinuousClock()
        let started = clock.now
        var firstChunkDelay: Duration?

        for try await event in runner.stream(invocation("echo first; sleep 2; echo second")) {
            if case .standardOutput = event, firstChunkDelay == nil {
                firstChunkDelay = clock.now - started
            }
        }

        let delay = try #require(firstChunkDelay)
        // The first line must arrive long before the process exits at ~2s.
        #expect(delay < .seconds(1.5))
    }

    @Test("Commands render as a pasteable line for diagnostics")
    func rendersCommandLine() {
        let invocation = ProcessInvocation(
            executableURL: URL(fileURLWithPath: "/usr/bin/claude"),
            arguments: ["--print", "hello world", "--model", "opus"]
        )
        #expect(invocation.commandLine == "/usr/bin/claude --print 'hello world' --model opus")
    }
}

@Suite("Executable discovery")
struct ExecutableLocatorTests {
    @Test("Finds an executable on the provided PATH without a shell")
    func findsOnPath() async {
        let locator = LoginShellExecutableLocator(hostEnvironment: ["PATH": "/bin:/usr/bin"])
        let found = await locator.locate("sh")
        #expect(found?.path == "/bin/sh")
    }

    @Test("Honours an explicit override")
    func honoursOverride() async {
        let locator = LoginShellExecutableLocator(
            hostEnvironment: ["PATH": "/nowhere"],
            overrides: ["claude": URL(fileURLWithPath: "/bin/sh")]
        )
        let found = await locator.locate("claude")
        #expect(found?.path == "/bin/sh")
    }

    @Test("Rejects an override that is not executable")
    func rejectsBadOverride() async {
        let locator = LoginShellExecutableLocator(
            overrides: ["claude": URL(fileURLWithPath: "/etc/hosts")]
        )
        #expect(await locator.locate("claude") == nil)
    }

    /// GUI apps launched from Finder get a minimal PATH with no Homebrew and no
    /// `~/.local/bin`. The fallback list is what keeps discovery working there.
    @Test("Falls back to well-known install locations when PATH is bare")
    func fallsBackToWellKnownDirectories() async {
        let locator = LoginShellExecutableLocator(hostEnvironment: ["PATH": "/nonexistent"])
        // /bin is in the well-known list and always present on macOS.
        let found = await locator.locate("sh")
        #expect(found?.path == "/bin/sh")
    }

    @Test("Caches results, including negative ones")
    func cachesResults() async {
        let locator = LoginShellExecutableLocator(hostEnvironment: ["PATH": "/bin"])
        let first = await locator.locate("sh")
        let second = await locator.locate("sh")
        #expect(first == second)

        await locator.invalidate()
        let afterInvalidation = await locator.locate("sh")
        #expect(afterInvalidation == first)
    }

    @Test("A static locator answers exactly what it was told")
    func staticLocator() async {
        let locator = StaticExecutableLocator(["claude": URL(fileURLWithPath: "/opt/claude")])
        #expect(await locator.locate("claude")?.path == "/opt/claude")
        #expect(await locator.locate("codex") == nil)
    }
}
