import AgenticCLIKit
import Foundation

/// A ``ProcessRunner`` that replays recorded CLI output instead of spawning
/// anything.
///
/// This is how adapters are tested without the CLIs installed, without network
/// access, and without spending tokens. Record a real transcript once, commit
/// it, and every future run asserts against the exact bytes the CLI produced.
///
/// Shipped as a public product so apps embedding the kit can test their own
/// agent-driven flows the same way.
public final class RecordedProcessRunner: ProcessRunner, @unchecked Sendable {
    /// What the fake process produces.
    public struct Recording: Sendable {
        public var standardOutput: Data
        public var standardError: Data
        public var exitCode: Int32
        /// Split stdout into chunks of this size to exercise line reassembly.
        /// `nil` delivers it in one piece.
        public var chunkSize: Int?
        /// Delay between chunks, for testing incremental UI updates.
        public var chunkDelay: Duration?
        /// When set, the stream fails with this error instead of exiting.
        public var failure: (any Error)?

        public init(
            standardOutput: Data = Data(),
            standardError: Data = Data(),
            exitCode: Int32 = 0,
            chunkSize: Int? = nil,
            chunkDelay: Duration? = nil,
            failure: (any Error)? = nil
        ) {
            self.standardOutput = standardOutput
            self.standardError = standardError
            self.exitCode = exitCode
            self.chunkSize = chunkSize
            self.chunkDelay = chunkDelay
            self.failure = failure
        }

        public static func output(_ text: String, exitCode: Int32 = 0) -> Recording {
            Recording(standardOutput: Data(text.utf8), exitCode: exitCode)
        }

        public static func failure(_ message: String, exitCode: Int32 = 1) -> Recording {
            Recording(standardError: Data(message.utf8), exitCode: exitCode)
        }

        /// Replays a fixture file, one JSONL chunk at a time, so the adapter's
        /// line reassembly is exercised rather than bypassed.
        public static func fixture(_ url: URL, chunkSize: Int? = 64) throws -> Recording {
            Recording(standardOutput: try Data(contentsOf: url), chunkSize: chunkSize)
        }
    }

    private let respond: @Sendable (ProcessInvocation) -> Recording
    private let lock = NSLock()
    private var recorded: [ProcessInvocation] = []

    /// - Parameter respond: called for each invocation; return what the fake
    ///   process should produce.
    public init(_ respond: @escaping @Sendable (ProcessInvocation) -> Recording) {
        self.respond = respond
    }

    /// Responds to every invocation with the same recording.
    public convenience init(always recording: Recording) {
        self.init { _ in recording }
    }

    /// Matches on the first argument that appears in a recording's key.
    ///
    /// ```swift
    /// RecordedProcessRunner(matching: [
    ///     "auth status": .output(#"{"loggedIn":true}"#),
    ///     "--print": try .fixture(streamFixtureURL),
    /// ])
    /// ```
    public convenience init(matching table: [String: Recording], fallback: Recording = .failure("no match")) {
        self.init { invocation in
            let commandLine = invocation.arguments.joined(separator: " ")
            let match = table.first { commandLine.contains($0.key) }
            return match?.value ?? fallback
        }
    }

    /// Every invocation seen so far, in order.
    public var invocations: [ProcessInvocation] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    /// The most recent invocation, for assertions about generated flags.
    public var lastInvocation: ProcessInvocation? {
        invocations.last
    }

    public func stream(_ invocation: ProcessInvocation) -> ProcessEventStream {
        lock.lock()
        recorded.append(invocation)
        lock.unlock()

        let recording = respond(invocation)

        return ProcessEventStream { continuation in
            let task = Task {
                do {
                    if let failure = recording.failure {
                        continuation.finish(throwing: failure)
                        return
                    }

                    for chunk in Self.split(recording.standardOutput, by: recording.chunkSize) {
                        try Task.checkCancellation()
                        continuation.yield(.standardOutput(chunk))
                        if let delay = recording.chunkDelay {
                            try await Task.sleep(for: delay)
                        }
                    }
                    if !recording.standardError.isEmpty {
                        continuation.yield(.standardError(recording.standardError))
                    }
                    continuation.yield(.exited(ProcessExit(code: recording.exitCode)))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func split(_ data: Data, by chunkSize: Int?) -> [Data] {
        guard let chunkSize, chunkSize > 0, data.count > chunkSize else {
            return data.isEmpty ? [] : [data]
        }
        var chunks: [Data] = []
        var index = data.startIndex
        while index < data.endIndex {
            let end = data.index(index, offsetBy: chunkSize, limitedBy: data.endIndex) ?? data.endIndex
            chunks.append(Data(data[index..<end]))
            index = end
        }
        return chunks
    }
}
