import AgenticCLIKit
import Foundation

/// A locator that claims every executable lives at a fixed path, so adapters
/// under test never touch the real filesystem or the user's shell.
public struct FakeExecutableLocator: ExecutableLocating {
    private let directory: URL
    private let missing: Set<String>

    /// - Parameters:
    ///   - directory: pretend every executable lives here.
    ///   - missing: names to report as not installed.
    public init(directory: URL = URL(fileURLWithPath: "/usr/local/bin"), missing: Set<String> = []) {
        self.directory = directory
        self.missing = missing
    }

    public func locate(_ executableName: String) async -> URL? {
        missing.contains(executableName) ? nil : directory.appendingPathComponent(executableName)
    }
}

extension RunConfiguration {
    /// A configuration suitable for tests: a temporary directory, read-only, short timeout.
    public static func testing(
        workingDirectory: URL = URL(fileURLWithPath: NSTemporaryDirectory()),
        permissions: PermissionPolicy = .readOnly
    ) -> RunConfiguration {
        RunConfiguration(
            workingDirectory: workingDirectory,
            permissions: permissions,
            timeout: .seconds(10)
        )
    }
}

extension AgentEventStream {
    /// Collects every event, for assertions about ordering and content.
    public func allEvents() async throws -> [AgentEvent] {
        var events: [AgentEvent] = []
        for try await event in self { events.append(event) }
        return events
    }
}

extension AgentEvent {
    /// A short, stable label for each case — makes failure messages readable
    /// when asserting on event sequences.
    public var kind: String {
        switch self {
        case .sessionStarted: return "sessionStarted"
        case .assistantTextDelta: return "assistantTextDelta"
        case .assistantMessage: return "assistantMessage"
        case .reasoningDelta: return "reasoningDelta"
        case .toolUseRequested: return "toolUseRequested"
        case .toolResult: return "toolResult"
        case .permissionDenied: return "permissionDenied"
        case .turnCompleted: return "turnCompleted"
        case .diagnostic: return "diagnostic"
        case .raw: return "raw"
        case .finished: return "finished"
        }
    }

    public var sessionReference: SessionReference? {
        if case let .sessionStarted(session) = self { return session }
        return nil
    }

    public var response: AgentResponse? {
        if case let .finished(response) = self { return response }
        return nil
    }

    public var text: String? {
        switch self {
        case let .assistantTextDelta(text), let .assistantMessage(text): return text
        default: return nil
        }
    }
}
