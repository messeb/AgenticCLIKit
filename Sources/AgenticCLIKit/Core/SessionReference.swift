import Foundation

/// A handle to a conversation living inside a CLI's own storage.
///
/// `Codable` on purpose: the host app persists this however it likes and hands
/// it back after a relaunch. The reference holds metadata only — the transcript
/// stays in the CLI's storage, which is exactly why resume works across
/// processes and reboots.
public struct SessionReference: Hashable, Sendable, Codable, Identifiable {
    public let cli: CLIIdentifier
    /// The CLI's own session/thread/conversation identifier.
    public let sessionID: String
    /// Directory the session was created in. Adapters without
    /// ``CLICapabilities/resumeAcrossDirectories`` validate against this.
    public let workingDirectory: URL
    public let createdAt: Date
    /// Updated each time the session is resumed through the kit.
    public var lastUsedAt: Date
    /// Optional caller-supplied label, for session pickers.
    public var title: String?
    /// Model used when the session was created, when known.
    public var model: String?

    public init(
        cli: CLIIdentifier,
        sessionID: String,
        workingDirectory: URL,
        createdAt: Date = Date(),
        lastUsedAt: Date? = nil,
        title: String? = nil,
        model: String? = nil
    ) {
        self.cli = cli
        self.sessionID = sessionID
        self.workingDirectory = workingDirectory
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt ?? createdAt
        self.title = title
        self.model = model
    }

    /// Stable across CLIs: two agents could in principle mint the same UUID.
    public var id: String { "\(cli.rawValue)/\(sessionID)" }

    public func touched(at date: Date = Date()) -> SessionReference {
        var copy = self
        copy.lastUsedAt = date
        return copy
    }
}
