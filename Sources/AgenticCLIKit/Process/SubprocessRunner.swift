#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// The production ``ProcessRunner``: real child processes, real pipes.
///
/// Guarantees that adapters rely on:
/// - stdin is always closed or fully written, so a CLI waiting for input cannot
///   hang the host app;
/// - the timeout and task cancellation both terminate the entire process tree;
/// - stdout and stderr are drained to EOF before the exit event is delivered, so
///   no output is lost to a fast-exiting child.
public struct SubprocessRunner: ProcessRunner {
    /// How long a `SIGTERM`ed process tree has to exit before `SIGKILL`.
    public let terminationGracePeriod: Duration
    /// Identifier used in errors, so failures name the CLI rather than the runner.
    private let cli: CLIIdentifier

    public init(cli: CLIIdentifier = "process", terminationGracePeriod: Duration = .seconds(5)) {
        self.cli = cli
        self.terminationGracePeriod = terminationGracePeriod
    }

    /// A runner that attributes its errors to `cli`.
    public func attributed(to cli: CLIIdentifier) -> SubprocessRunner {
        SubprocessRunner(cli: cli, terminationGracePeriod: terminationGracePeriod)
    }

    public func stream(_ invocation: ProcessInvocation) -> ProcessEventStream {
        let cli = self.cli
        let gracePeriod = terminationGracePeriod

        return ProcessEventStream { continuation in
            let supervisor = ChildProcessSupervisor(
                invocation: invocation,
                cli: cli,
                gracePeriod: gracePeriod,
                continuation: continuation
            )

            let task = Task { await supervisor.run() }

            continuation.onTermination = { termination in
                // A consumer that stops iterating must not leave an agent running.
                if case .cancelled = termination {
                    supervisor.abandon()
                }
                task.cancel()
            }
        }
    }
}

/// Owns one child process and translates its lifecycle into ``ProcessEvent``s.
///
/// `@unchecked Sendable` because the state is guarded by an explicit lock:
/// `Process` delivers its callbacks on arbitrary background queues, which no
/// actor isolation can express.
private final class ChildProcessSupervisor: @unchecked Sendable {
    private let invocation: ProcessInvocation
    private let cli: CLIIdentifier
    private let gracePeriod: Duration
    private let continuation: AsyncThrowingStream<ProcessEvent, any Error>.Continuation

    private let lock = NSLock()
    private var process: Process?
    private var childPID: pid_t = 0
    private var outputBytes = 0
    private var pendingFailure: AgenticCLIError?
    private var standardOutputAtEOF = false
    private var standardErrorAtEOF = false
    private var processDidExit = false
    private var completionWaiter: CheckedContinuation<Void, Never>?
    private var didSignalCompletion = false

    init(
        invocation: ProcessInvocation,
        cli: CLIIdentifier,
        gracePeriod: Duration,
        continuation: AsyncThrowingStream<ProcessEvent, any Error>.Continuation
    ) {
        self.invocation = invocation
        self.cli = cli
        self.gracePeriod = gracePeriod
        self.continuation = continuation
    }

    func run() async {
        let process: Process
        do {
            process = try launch()
        } catch let error as AgenticCLIError {
            continuation.finish(throwing: error)
            return
        } catch {
            continuation.finish(throwing: AgenticCLIError.launchFailed(cli, reason: "\(error)"))
            return
        }

        let timeoutTask = Task { [weak self] in
            try await Task.sleep(for: self?.invocation.timeout ?? .seconds(120))
            guard let self else { return }
            await self.fail(with: .timedOut(cli, after: invocation.timeout))
        }

        await withTaskCancellationHandler {
            await waitForCompletion()
        } onCancel: {
            self.abandon(reason: .cancelled(cli))
        }

        timeoutTask.cancel()

        let failure = lock.withLock { pendingFailure }
        if let failure {
            continuation.finish(throwing: failure)
            return
        }

        let exit = ProcessExit(
            code: process.terminationStatus,
            signal: process.terminationReason == .uncaughtSignal ? process.terminationStatus : nil
        )
        continuation.yield(.exited(exit))
        continuation.finish()
    }

    // MARK: - Launch

    private func launch() throws -> Process {
        try validateExecutable()
        try validateWorkingDirectory()

        let process = Process()
        process.executableURL = invocation.executableURL
        process.arguments = invocation.arguments
        process.environment = invocation.environment
        if let workingDirectory = invocation.workingDirectory {
            process.currentDirectoryURL = workingDirectory
        }

        let standardOutput = Pipe()
        let standardError = Pipe()
        let standardInput = Pipe()
        process.standardOutput = standardOutput
        process.standardError = standardError
        process.standardInput = standardInput

        standardOutput.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.handleOutput(handle.availableData, isStandardError: false)
        }
        standardError.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.handleOutput(handle.availableData, isStandardError: true)
        }
        process.terminationHandler = { [weak self] _ in
            self?.markProcessExited()
        }

        do {
            try process.run()
        } catch {
            throw AgenticCLIError.launchFailed(cli, reason: error.localizedDescription)
        }

        lock.withLock {
            self.process = process
            self.childPID = process.processIdentifier
        }

        writeStandardInput(to: standardInput)
        return process
    }

    private func validateExecutable() throws {
        let path = invocation.executableURL.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw AgenticCLIError.launchFailed(cli, reason: "No executable at \(path)")
        }
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw AgenticCLIError.launchFailed(cli, reason: "Not executable: \(path)")
        }
    }

    private func validateWorkingDirectory() throws {
        guard let workingDirectory = invocation.workingDirectory else { return }
        var isDirectory: ObjCBool = false
        guard
            FileManager.default.fileExists(atPath: workingDirectory.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw AgenticCLIError.invalidWorkingDirectory(workingDirectory)
        }
    }

    /// Writes stdin off the calling thread and always closes it.
    ///
    /// Closing is the important half: several agent CLIs block reading stdin
    /// when it stays open, which is the classic "the app froze" bug report.
    private func writeStandardInput(to pipe: Pipe) {
        let data = invocation.standardInput
        DispatchQueue.global(qos: .utility).async {
            let handle = pipe.fileHandleForWriting
            if let data, !data.isEmpty {
                // The child may exit before reading everything; a broken pipe
                // here is expected, not exceptional.
                try? handle.write(contentsOf: data)
            }
            try? handle.close()
        }
    }

    // MARK: - Output

    private func handleOutput(_ data: Data, isStandardError: Bool) {
        if data.isEmpty {
            lock.withLock {
                if isStandardError { standardErrorAtEOF = true } else { standardOutputAtEOF = true }
            }
            signalCompletionIfReady()
            return
        }

        let exceeded: Bool = lock.withLock {
            outputBytes += data.count
            return outputBytes > invocation.maximumOutputBytes
        }

        continuation.yield(isStandardError ? .standardError(data) : .standardOutput(data))

        if exceeded {
            let bytes = lock.withLock { outputBytes }
            abandon(reason: .outputLimitExceeded(cli, bytes: bytes))
        }
    }

    private func markProcessExited() {
        lock.withLock { processDidExit = true }
        signalCompletionIfReady()
    }

    /// Completion requires the process to have exited *and* both pipes to have
    /// reached EOF, otherwise a fast-exiting child loses its last output.
    private func signalCompletionIfReady() {
        let waiter: CheckedContinuation<Void, Never>? = lock.withLock {
            guard processDidExit, standardOutputAtEOF, standardErrorAtEOF, !didSignalCompletion else {
                return nil
            }
            didSignalCompletion = true
            defer { completionWaiter = nil }
            return completionWaiter
        }
        waiter?.resume()
    }

    private func waitForCompletion() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let alreadyComplete: Bool = lock.withLock {
                if didSignalCompletion { return true }
                if processDidExit, standardOutputAtEOF, standardErrorAtEOF {
                    didSignalCompletion = true
                    return true
                }
                completionWaiter = continuation
                return false
            }
            if alreadyComplete {
                continuation.resume()
            }
        }
    }

    // MARK: - Termination

    /// Records a failure and tears the process tree down, awaiting the grace period.
    private func fail(with error: AgenticCLIError) async {
        let pid: pid_t = lock.withLock {
            if pendingFailure == nil { pendingFailure = error }
            return childPID
        }
        await ProcessTree.terminate(pid: pid, gracePeriod: gracePeriod)
        // The tree is gone but the pipes may not have reported EOF; unblock the
        // waiter so the caller sees the failure rather than hanging on cleanup.
        forceCompletion()
    }

    /// Synchronous teardown for cancellation paths that cannot await.
    fileprivate func abandon(reason: AgenticCLIError? = nil) {
        let pid: pid_t = lock.withLock {
            // A process that already exited was not cancelled; do not rewrite history.
            if let reason, pendingFailure == nil, !processDidExit { pendingFailure = reason }
            return processDidExit ? 0 : childPID
        }
        guard pid > 0 else { return }
        let gracePeriod = self.gracePeriod
        Task.detached(priority: .userInitiated) {
            await ProcessTree.terminate(pid: pid, gracePeriod: gracePeriod)
        }
    }

    private func forceCompletion() {
        let waiter: CheckedContinuation<Void, Never>? = lock.withLock {
            guard !didSignalCompletion else { return nil }
            didSignalCompletion = true
            defer { completionWaiter = nil }
            return completionWaiter
        }
        waiter?.resume()
    }
}

