import Foundation

/// A tool invocation the agent requested.
public struct ToolInvocation: Sendable, Hashable {
    /// CLI-assigned identifier, used to correlate with ``ToolOutcome``.
    public let id: String?
    public let name: String
    /// Raw JSON input, left undecoded because tool schemas are per-CLI.
    public let input: Data?
    /// A short human-readable summary when the CLI provides one.
    public let summary: String?

    public init(id: String? = nil, name: String, input: Data? = nil, summary: String? = nil) {
        self.id = id
        self.name = name
        self.input = input
        self.summary = summary
    }
}

/// The result of a tool invocation.
public struct ToolOutcome: Sendable, Hashable {
    public let id: String?
    public let name: String?
    public let output: Data?
    public let isError: Bool

    public init(id: String? = nil, name: String? = nil, output: Data? = nil, isError: Bool = false) {
        self.id = id
        self.name = name
        self.output = output
        self.isError = isError
    }
}

/// An incremental event from a streaming run.
///
/// Deliberately not a lowest-common-denominator schema. Adapters map what maps
/// cleanly and pass everything else through ``raw(_:)``, which ages far better
/// than forcing four fast-moving CLIs into one shape.
public enum AgentEvent: Sendable {
    /// The CLI created or attached to a resumable session. Always the first
    /// event that carries a ``SessionReference``.
    case sessionStarted(SessionReference)
    /// A fragment of assistant text, in order.
    case assistantTextDelta(String)
    /// A complete assistant message. Adapters that cannot stream deltas emit
    /// only this.
    case assistantMessage(String)
    /// A fragment of reasoning/thinking text, where the CLI exposes it.
    case reasoningDelta(String)
    case toolUseRequested(ToolInvocation)
    case toolResult(ToolOutcome)
    /// A tool call the permission policy blocked.
    case permissionDenied(tool: String, reason: String?)
    case turnCompleted(UsageInfo?)
    /// A line the CLI wrote to stderr. Diagnostics, not output.
    case diagnostic(String)
    /// An event the adapter chose not to model. The raw JSON line.
    case raw(Data)
    /// Terminal event. Always the last element of a successful stream.
    case finished(AgentResponse)
}

/// An `AsyncSequence` of ``AgentEvent`` values.
///
/// Wrapping the concrete stream keeps `AsyncThrowingStream` an implementation
/// detail, so adapters can change how they produce events — and the kit can
/// adopt typed throws — without breaking callers.
///
/// To stop a run early, cancel the `Task` consuming the stream. Breaking out of
/// the loop terminates the CLI only once the stream value is released, so a
/// stream stored in a property keeps its agent alive until that property is
/// cleared.
public struct AgentEventStream: AsyncSequence, Sendable {
    public typealias Element = AgentEvent

    private let base: AsyncThrowingStream<AgentEvent, any Error>

    public init(_ base: AsyncThrowingStream<AgentEvent, any Error>) {
        self.base = base
    }

    /// Builds a stream from a producing closure, mirroring
    /// `AsyncThrowingStream.init(_:_:_:)`.
    public init(
        bufferingPolicy: AsyncThrowingStream<AgentEvent, any Error>.Continuation.BufferingPolicy = .unbounded,
        _ build: @Sendable @escaping (AsyncThrowingStream<AgentEvent, any Error>.Continuation) -> Void
    ) {
        self.base = AsyncThrowingStream(AgentEvent.self, bufferingPolicy: bufferingPolicy, build)
    }

    /// A stream that immediately fails with `error`.
    public static func failing(with error: any Error) -> AgentEventStream {
        AgentEventStream { continuation in
            continuation.finish(throwing: error)
        }
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        var base: AsyncThrowingStream<AgentEvent, any Error>.AsyncIterator

        public mutating func next() async throws -> AgentEvent? {
            try await base.next()
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(base: base.makeAsyncIterator())
    }
}

extension AgentEventStream {
    /// Consumes the stream and returns the terminal ``AgentEvent/finished(_:)``
    /// payload.
    ///
    /// This is how every adapter's `run` is implemented, which guarantees the
    /// buffered and streaming paths cannot drift apart in what they report.
    public func collected() async throws -> AgentResponse {
        var response: AgentResponse?
        for try await event in self {
            if case let .finished(finished) = event {
                response = finished
            }
        }
        guard let response else {
            throw AgenticCLIError.malformedOutput(reason: "Stream ended without a final result", raw: nil)
        }
        return response
    }

    /// Just the assistant text, concatenated in order. Prefers deltas and falls
    /// back to whole messages for adapters that do not stream.
    public var textFragments: AsyncThrowingMapSequence<AsyncThrowingFilterSequence<AgentEventStream>, String> {
        self
            .filter { event in
                switch event {
                case .assistantTextDelta, .assistantMessage: return true
                default: return false
                }
            }
            .map { event in
                switch event {
                case let .assistantTextDelta(text): return text
                case let .assistantMessage(text): return text
                default: return ""
                }
            }
    }
}
