import Foundation

/// A ``SessionStore`` backed by a JSON file in Application Support.
///
/// Writes are atomic, so a crash mid-save cannot leave a truncated index and
/// lose every stored session. Reads are cached in memory after the first load.
public actor FileSessionStore: SessionStore {
    private let fileURL: URL
    private let fileManager: FileManager
    /// Sessions older than this are dropped on load. CLIs expire their own
    /// transcripts eventually, and a store full of unresumable IDs is worse
    /// than empty.
    private let maximumAge: Duration?
    private var cache: [String: SessionReference]?

    /// - Parameters:
    ///   - fileURL: where to store the index.
    ///   - maximumAge: prune sessions untouched for longer than this. Pass `nil`
    ///     to keep everything.
    ///   - fileManager: injection point for tests.
    public init(
        fileURL: URL,
        maximumAge: Duration? = .seconds(60 * 60 * 24 * 30),
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.maximumAge = maximumAge
        self.fileManager = fileManager
    }

    /// The default location: `~/Library/Application Support/<bundle id>/agentic-sessions.json`.
    public static func applicationSupport(
        subdirectory: String? = nil,
        fileManager: FileManager = .default
    ) throws -> FileSessionStore {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let folderName = subdirectory
            ?? Bundle.main.bundleIdentifier
            ?? "AgenticCLIKit"
        let directory = base.appendingPathComponent(folderName, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return FileSessionStore(fileURL: directory.appendingPathComponent("agentic-sessions.json"))
    }

    public func save(_ session: SessionReference) async throws {
        var sessions = try load()
        sessions[session.id] = session
        try persist(sessions)
    }

    public func remove(_ session: SessionReference) async throws {
        var sessions = try load()
        sessions.removeValue(forKey: session.id)
        try persist(sessions)
    }

    public func sessions(for cli: CLIIdentifier?) async throws -> [SessionReference] {
        try load().values
            .filter { cli == nil || $0.cli == cli }
            .sorted { $0.lastUsedAt > $1.lastUsedAt }
    }

    public func session(id sessionID: String, cli: CLIIdentifier) async throws -> SessionReference? {
        try load()["\(cli.rawValue)/\(sessionID)"]
    }

    /// Drops every stored session.
    public func removeAll() throws {
        cache = [:]
        try? fileManager.removeItem(at: fileURL)
    }

    // MARK: - Storage

    private func load() throws -> [String: SessionReference] {
        if let cache { return cache }

        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else {
            cache = [:]
            return [:]
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let stored: [SessionReference]
        do {
            stored = try decoder.decode([SessionReference].self, from: data)
        } catch {
            // A corrupt index must not brick session recovery for good; start
            // fresh and let the CLIs' own storage remain the source of truth.
            Log.warning(.session, "Discarding unreadable session index at \(fileURL.path)")
            cache = [:]
            return [:]
        }

        let cutoff = maximumAge.map { Date().addingTimeInterval(-$0.seconds) }
        var sessions: [String: SessionReference] = [:]
        for session in stored where cutoff == nil || session.lastUsedAt >= cutoff! {
            sessions[session.id] = session
        }
        cache = sessions
        return sessions
    }

    private func persist(_ sessions: [String: SessionReference]) throws {
        cache = sessions
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(sessions.values.sorted { $0.lastUsedAt > $1.lastUsedAt })

        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        // Atomic: a crash here leaves the previous index intact.
        try data.write(to: fileURL, options: [.atomic])
    }
}
