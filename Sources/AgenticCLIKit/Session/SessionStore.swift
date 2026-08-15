import Foundation

/// Persistence for ``SessionReference`` values.
///
/// The store holds metadata only — identifiers, directories, timestamps. The
/// conversation itself stays in the CLI's own storage, which is precisely why
/// resume survives an app relaunch. Nothing here is a transcript, so nothing
/// here needs encryption beyond the app's normal file protection.
public protocol SessionStore: Sendable {
    func save(_ session: SessionReference) async throws
    func remove(_ session: SessionReference) async throws
    /// All sessions, newest use first. Pass `nil` for every CLI.
    func sessions(for cli: CLIIdentifier?) async throws -> [SessionReference]
    func session(id sessionID: String, cli: CLIIdentifier) async throws -> SessionReference?
}

extension SessionStore {
    /// The session most recently used for `cli`, optionally scoped to a directory.
    ///
    /// Directory scoping matters for adapters without
    /// ``CLICapabilities/resumeAcrossDirectories``.
    public func mostRecentSession(
        for cli: CLIIdentifier,
        in workingDirectory: URL? = nil
    ) async throws -> SessionReference? {
        let candidates = try await sessions(for: cli)
        guard let workingDirectory else { return candidates.first }
        let target = workingDirectory.standardizedFileURL
        return candidates.first { $0.workingDirectory.standardizedFileURL == target }
    }

    /// Saves the session attached to a response, if there is one.
    @discardableResult
    public func record(_ response: AgentResponse) async throws -> SessionReference? {
        guard let session = response.session else { return nil }
        try await save(session.touched())
        return session
    }
}

/// A session store held in memory. Useful for tests and for apps that manage
/// their own persistence.
public actor InMemorySessionStore: SessionStore {
    private var storage: [String: SessionReference] = [:]

    public init(_ sessions: [SessionReference] = []) {
        for session in sessions { storage[session.id] = session }
    }

    public func save(_ session: SessionReference) async throws {
        storage[session.id] = session
    }

    public func remove(_ session: SessionReference) async throws {
        storage.removeValue(forKey: session.id)
    }

    public func sessions(for cli: CLIIdentifier?) async throws -> [SessionReference] {
        storage.values
            .filter { cli == nil || $0.cli == cli }
            .sorted { $0.lastUsedAt > $1.lastUsedAt }
    }

    public func session(id sessionID: String, cli: CLIIdentifier) async throws -> SessionReference? {
        storage["\(cli.rawValue)/\(sessionID)"]
    }
}
