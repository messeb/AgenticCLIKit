import Foundation

/// A child process to spawn.
public struct ProcessInvocation: Hashable, Sendable {
    public var executableURL: URL
    public var arguments: [String]
    public var workingDirectory: URL?
    /// The complete environment for the child. Never merged with the host
    /// environment by the runner — resolve an ``EnvironmentPolicy`` first.
    public var environment: [String: String]
    /// Data written to stdin. `nil` closes stdin immediately.
    public var standardInput: Data?
    public var timeout: Duration
    public var maximumOutputBytes: Int

    public init(
        executableURL: URL,
        arguments: [String] = [],
        workingDirectory: URL? = nil,
        environment: [String: String] = [:],
        standardInput: Data? = nil,
        timeout: Duration = .seconds(120),
        maximumOutputBytes: Int = 32 * 1024 * 1024
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.standardInput = standardInput
        self.timeout = timeout
        self.maximumOutputBytes = maximumOutputBytes
    }

    /// The command line as a user could paste it, with arguments quoted.
    /// Intended for diagnostics; prompts are not redacted here, so callers
    /// decide whether it is safe to log.
    public var commandLine: String {
        ([executableURL.path] + arguments)
            .map { argument in
                argument.contains(where: { $0 == " " || $0 == "\"" || $0 == "'" })
                    ? "'\(argument.replacingOccurrences(of: "'", with: #"'\''"#))'"
                    : argument
            }
            .joined(separator: " ")
    }
}

/// Incremental output from a running child.
public enum ProcessEvent: Sendable, Hashable {
    case standardOutput(Data)
    case standardError(Data)
    /// Always the final element of a stream that ran to completion.
    case exited(ProcessExit)
}

/// How a child process ended.
public struct ProcessExit: Hashable, Sendable {
    public let code: Int32
    /// The signal that killed the process, when it was signalled.
    public let signal: Int32?

    public init(code: Int32, signal: Int32? = nil) {
        self.code = code
        self.signal = signal
    }

    public var isSuccess: Bool { code == 0 && signal == nil }
}

/// Buffered result of a completed child process.
public struct ProcessResult: Sendable {
    public let invocation: ProcessInvocation
    public let exit: ProcessExit
    public let standardOutput: Data
    public let standardError: Data
    public let duration: Duration

    public init(
        invocation: ProcessInvocation,
        exit: ProcessExit,
        standardOutput: Data,
        standardError: Data,
        duration: Duration
    ) {
        self.invocation = invocation
        self.exit = exit
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.duration = duration
    }

    public var standardOutputText: String {
        String(decoding: standardOutput, as: UTF8.self)
    }

    public var standardErrorText: String {
        String(decoding: standardError, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// An `AsyncSequence` of ``ProcessEvent`` values.
public struct ProcessEventStream: AsyncSequence, Sendable {
    public typealias Element = ProcessEvent

    private let base: AsyncThrowingStream<ProcessEvent, any Error>

    public init(_ base: AsyncThrowingStream<ProcessEvent, any Error>) {
        self.base = base
    }

    public init(
        bufferingPolicy: AsyncThrowingStream<ProcessEvent, any Error>.Continuation.BufferingPolicy = .unbounded,
        _ build: @Sendable @escaping (AsyncThrowingStream<ProcessEvent, any Error>.Continuation) -> Void
    ) {
        self.base = AsyncThrowingStream(ProcessEvent.self, bufferingPolicy: bufferingPolicy, build)
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        var base: AsyncThrowingStream<ProcessEvent, any Error>.AsyncIterator

        public mutating func next() async throws -> ProcessEvent? {
            try await base.next()
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(base: base.makeAsyncIterator())
    }
}

/// The seam between adapters and the operating system.
///
/// Every adapter talks to the world exclusively through this protocol, which is
/// what makes them testable against recorded CLI transcripts. See
/// `AgenticCLIKitTesting.RecordedProcessRunner`.
public protocol ProcessRunner: Sendable {
    /// Spawns the process and streams its output as it arrives.
    ///
    /// Implementations must terminate the child and its descendants when the
    /// consuming task is cancelled or ``ProcessInvocation/timeout`` elapses.
    ///
    /// To stop a run early, cancel the consuming `Task`. Simply breaking out of
    /// the `for await` loop only terminates the child once the stream value
    /// itself is released — if a long-lived object still holds the stream, the
    /// agent keeps running. Cancellation is the reliable signal.
    func stream(_ invocation: ProcessInvocation) -> ProcessEventStream

    /// Spawns the process and buffers its output.
    func run(_ invocation: ProcessInvocation) async throws -> ProcessResult
}

extension ProcessRunner {
    /// Default `run` built on ``stream(_:)``, so a conforming type only has to
    /// implement one path.
    public func run(_ invocation: ProcessInvocation) async throws -> ProcessResult {
        let clock = ContinuousClock()
        let start = clock.now
        var standardOutput = Data()
        var standardError = Data()
        var exit: ProcessExit?

        for try await event in stream(invocation) {
            switch event {
            case let .standardOutput(chunk):
                standardOutput.append(chunk)
            case let .standardError(chunk):
                standardError.append(chunk)
            case let .exited(processExit):
                exit = processExit
            }
        }

        guard let exit else {
            throw AgenticCLIError.malformedOutput(
                reason: "Process stream ended without an exit event",
                raw: nil
            )
        }

        return ProcessResult(
            invocation: invocation,
            exit: exit,
            standardOutput: standardOutput,
            standardError: standardError,
            duration: clock.now - start
        )
    }
}
