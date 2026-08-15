import Foundation

/// A snapshot of every registered CLI: installed, current, signed in.
///
/// Built for two jobs — rendering a status screen, and pasting into a bug
/// report. It is `Codable` for the second one, and contains no prompts, no
/// tokens, and no account identifiers beyond what the user can already see in
/// their own terminal.
public struct HealthReport: Sendable, Codable {
    public let generatedAt: Date
    /// The version of this package, so a pasted report names its own build.
    public let kitVersion: String
    public let entries: [Entry]

    public init(
        generatedAt: Date = Date(),
        kitVersion: String = AgenticCLIKit.version,
        entries: [Entry]
    ) {
        self.generatedAt = generatedAt
        self.kitVersion = kitVersion
        self.entries = entries
    }

    private enum CodingKeys: String, CodingKey {
        case generatedAt, kitVersion, entries
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        // Tolerated so a report written by an older build still decodes.
        kitVersion = try container.decodeIfPresent(String.self, forKey: .kitVersion) ?? "unknown"
        entries = try container.decode([Entry].self, forKey: .entries)
    }

    public struct Entry: Sendable, Codable {
        public let cli: CLIIdentifier
        public let displayName: String
        public let capabilities: CLICapabilities
        public let isInstalled: Bool
        public let executablePath: String?
        public let version: String?
        public let minimumSupportedVersion: String
        public let meetsMinimumVersion: Bool
        public let authenticationSummary: String
        public let isAuthenticated: Bool
        public let isReady: Bool
        /// What stands in the way, in a form safe to show a user.
        public let blocker: String?
        /// What the user should do next, when there is an obvious action.
        public let suggestedAction: String?
        /// How long the probes took, for spotting a CLI that hangs on startup.
        public let probeSeconds: Double

        public init(
            cli: CLIIdentifier,
            displayName: String,
            capabilities: CLICapabilities,
            readiness: Readiness,
            probeDuration: Duration
        ) {
            self.cli = cli
            self.displayName = displayName
            self.capabilities = capabilities
            self.isInstalled = readiness.installation.isInstalled
            self.executablePath = readiness.installation.executableURL?.path
            self.version = readiness.installation.version?.description
            self.minimumSupportedVersion = readiness.installation.minimumSupportedVersion.description
            self.meetsMinimumVersion = readiness.installation.meetsMinimumVersion
            self.authenticationSummary = readiness.authentication.description
            self.isAuthenticated = readiness.authentication.isAuthenticated
            self.isReady = readiness.isReady
            self.blocker = readiness.blocker?.localizedDescription
            self.suggestedAction = readiness.blocker?.recoverySuggestion
            self.probeSeconds = probeDuration.seconds
        }
    }

    /// CLIs that can run work right now.
    public var readyCLIs: [CLIIdentifier] {
        entries.filter(\.isReady).map(\.cli)
    }

    /// A plain-text summary, for logs and bug reports.
    public func formattedSummary() -> String {
        var lines = [
            "AgenticCLIKit \(kitVersion) health — \(ISO8601DateFormatter().string(from: generatedAt))",
        ]
        for entry in entries {
            let mark = entry.isReady ? "✓" : "✗"
            var line = "\(mark) \(entry.displayName)"
            if let version = entry.version { line += " \(version)" }
            if !entry.isInstalled {
                line += " — not installed"
            } else if !entry.meetsMinimumVersion {
                line += " — below minimum \(entry.minimumSupportedVersion)"
            } else {
                line += " — \(entry.authenticationSummary)"
            }
            lines.append(line)
            if let action = entry.suggestedAction {
                lines.append("    → \(action)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
