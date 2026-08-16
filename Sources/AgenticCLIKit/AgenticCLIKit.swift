import Foundation

/// The entry point: a registry of adapters plus the session bookkeeping most
/// apps would otherwise write themselves.
///
/// ```swift
/// let kit = AgenticCLIKit()
/// let report = await kit.healthReport()
///
/// let response = try await kit.run(
///     "Summarise the uncommitted changes",
///     using: .claudeCode,
///     configuration: .readOnly(in: repositoryURL)
/// )
/// // response.session was saved for you; resume it after a relaunch.
/// ```
///
/// Using an adapter directly is equally supported — the facade adds readiness
/// checks and session persistence, not capability.
public struct AgenticCLIKit: Sendable {
    public let agents: [any AgenticCLI]
    public let sessionStore: any SessionStore
    /// Shared by copies of the value, so a struct passed around a SwiftUI view
    /// hierarchy does not re-probe once per copy.
    private let cache = HealthReportCache()

    /// - Parameters:
    ///   - agents: adapters to register. Defaults to all four shipped adapters.
    ///   - sessionStore: where ``SessionReference`` values are recorded.
    ///     In-memory by default, so nothing is written to disk unless asked.
    public init(
        agents: [any AgenticCLI] = AgenticCLIKit.defaultAgents(),
        sessionStore: any SessionStore = InMemorySessionStore()
    ) {
        self.agents = agents
        self.sessionStore = sessionStore
    }

    /// Every adapter the package ships, sharing one executable locator so the
    /// login-shell `PATH` lookup happens once rather than four times.
    public static func defaultAgents(
        locator: any ExecutableLocating = LoginShellExecutableLocator()
    ) -> [any AgenticCLI] {
        [
            ClaudeCode.Adapter(locator: locator),
            Codex.Adapter(locator: locator),
            Copilot.Adapter(locator: locator),
            Antigravity.Adapter(locator: locator),
            Vibe.Adapter(locator: locator),
        ]
    }

    /// The registered adapter for `identifier`, if any.
    public subscript(identifier: CLIIdentifier) -> (any AgenticCLI)? {
        agents.first { $0.identifier == identifier }
    }

    /// The registered adapter, or ``AgenticCLIError/notInstalled(_:installHint:)``
    /// when nothing is registered for that CLI.
    public func agent(for identifier: CLIIdentifier) throws -> any AgenticCLI {
        guard let agent = self[identifier] else {
            throw AgenticCLIError.notInstalled(identifier, installHint: "No adapter registered for \(identifier)")
        }
        return agent
    }

    /// Adapters whose capabilities include everything in `required`.
    public func agents(supporting required: CLICapabilities) -> [any AgenticCLI] {
        agents.filter { $0.capabilities.isSuperset(of: required) }
    }

    // MARK: - Diagnostics

    /// Probes every registered CLI concurrently.
    ///
    /// Concurrency is the point: four sequential login-shell lookups plus four
    /// auth probes would take seconds on a cold start.
    ///
    /// Cold-probe cost is dominated by whichever CLI checks credentials over the
    /// network. Locally-checked CLIs (`claude`, `codex`, `copilot`) come back in
    /// roughly half a second combined; `agy` has no local credential check and
    /// costs about two seconds on its own. Pass `maximumAge` on repeat calls —
    /// a status bar refreshing every few seconds should not re-probe every time.
    ///
    /// - Parameter maximumAge: reuse a previous report if it is younger than
    ///   this. `nil` always probes afresh.
    public func healthReport(maximumAge: Duration? = nil) async -> HealthReport {
        if let maximumAge, let cached = cache.report(newerThan: maximumAge) {
            return cached
        }
        let report = await probeAll()
        cache.store(report)
        return report
    }

    /// Discards any cached report, e.g. after the user signs in.
    public func invalidateHealthReport() {
        cache.clear()
    }

    private func probeAll() async -> HealthReport {
        let entries = await withTaskGroup(of: (Int, HealthReport.Entry).self) { group in
            for (index, agent) in agents.enumerated() {
                group.addTask {
                    let clock = ContinuousClock()
                    let started = clock.now
                    let readiness = await agent.readiness()
                    return (index, HealthReport.Entry(
                        cli: agent.identifier,
                        displayName: agent.displayName,
                        capabilities: agent.capabilities,
                        readiness: readiness,
                        probeDuration: clock.now - started
                    ))
                }
            }

            var collected: [(Int, HealthReport.Entry)] = []
            for await entry in group { collected.append(entry) }
            // Restore registration order; task completion order is arbitrary.
            return collected.sorted { $0.0 < $1.0 }.map(\.1)
        }
        return HealthReport(entries: entries)
    }

    /// Holds the most recent report. A reference type because the kit is a
    /// value, and the cache has to survive being copied.
    private final class HealthReportCache: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: (report: HealthReport, at: ContinuousClock.Instant)?

        func report(newerThan maximumAge: Duration) -> HealthReport? {
            lock.lock()
            defer { lock.unlock() }
            guard let stored, ContinuousClock().now - stored.at < maximumAge else { return nil }
            return stored.report
        }

        func store(_ report: HealthReport) {
            lock.lock()
            defer { lock.unlock() }
            stored = (report, ContinuousClock().now)
        }

        func clear() {
            lock.lock()
            defer { lock.unlock() }
            stored = nil
        }
    }

    // MARK: - Running

    /// Verifies readiness, runs the prompt, and records any session created.
    public func run(
        _ prompt: String,
        using identifier: CLIIdentifier,
        configuration: RunConfiguration
    ) async throws -> AgentResponse {
        let agent = try agent(for: identifier)
        try await agent.verifyReady()
        let response = try await agent.run(prompt, configuration: configuration)
        _ = try? await sessionStore.record(response)
        return response
    }

    /// Streams a run, recording the session as soon as it is announced.
    ///
    /// Recording on ``AgentEvent/sessionStarted(_:)`` rather than at the end is
    /// deliberate: a run that is cancelled halfway still leaves a resumable
    /// conversation, and losing its ID would strand the user's work.
    public func stream(
        _ prompt: String,
        using identifier: CLIIdentifier,
        configuration: RunConfiguration
    ) -> AgentEventStream {
        do {
            let agent = try agent(for: identifier)
            let store = sessionStore
            return AgentEventStream { continuation in
                let task = Task {
                    do {
                        try await agent.verifyReady()
                        for try await event in agent.stream(prompt, configuration: configuration) {
                            if case let .sessionStarted(session) = event {
                                try? await store.save(session)
                            }
                            continuation.yield(event)
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        } catch {
            return .failing(with: error)
        }
    }

    /// Continues a stored session.
    public func resume(
        _ session: SessionReference,
        with prompt: String,
        configuration: RunConfiguration
    ) async throws -> AgentResponse {
        let agent = try agent(for: session.cli)
        try agent.requireCapabilities(.sessions)
        try await agent.verifyReady()
        let response = try await agent.resume(session, with: prompt, configuration: configuration)
        try? await sessionStore.save(session.touched())
        _ = try? await sessionStore.record(response)
        return response
    }

    /// Continues the most recent stored session for `identifier`, or starts a
    /// new one when there is nothing to resume.
    ///
    /// This is the "continue where we left off" button, including the case where
    /// the CLI has since forgotten the session.
    public func continueOrStart(
        _ prompt: String,
        using identifier: CLIIdentifier,
        configuration: RunConfiguration
    ) async throws -> AgentResponse {
        let agent = try agent(for: identifier)
        let scopedDirectory = agent.capabilities.contains(.resumeAcrossDirectories)
            ? nil
            : configuration.workingDirectory

        if agent.capabilities.contains(.sessions),
           let session = try? await sessionStore.mostRecentSession(for: identifier, in: scopedDirectory) {
            do {
                return try await resume(session, with: prompt, configuration: configuration)
            } catch let error as AgenticCLIError {
                switch error {
                case .sessionNotFound, .sessionExpired, .workingDirectoryMismatch:
                    // The CLI forgot it; drop the stale reference and start over.
                    try? await sessionStore.remove(session)
                default:
                    throw error
                }
            }
        }
        return try await run(prompt, using: identifier, configuration: configuration)
    }
}
