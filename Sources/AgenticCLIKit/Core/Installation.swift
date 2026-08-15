import Foundation

/// Where a CLI lives on disk and whether the installed build is usable.
///
/// Producing an `Installation` never triggers a login prompt or opens a browser.
public struct Installation: Hashable, Sendable, Codable {
    public let cli: CLIIdentifier
    /// Resolved absolute path, or `nil` when the executable could not be found.
    public let executableURL: URL?
    /// Parsed `--version` output, or `nil` when the probe failed.
    public let version: SemanticVersion?
    /// The oldest release this adapter is written against.
    public let minimumSupportedVersion: SemanticVersion
    /// How to install the CLI, for display in a "not installed" UI.
    public let installHint: String

    public init(
        cli: CLIIdentifier,
        executableURL: URL?,
        version: SemanticVersion?,
        minimumSupportedVersion: SemanticVersion,
        installHint: String
    ) {
        self.cli = cli
        self.executableURL = executableURL
        self.version = version
        self.minimumSupportedVersion = minimumSupportedVersion
        self.installHint = installHint
    }

    public var isInstalled: Bool { executableURL != nil }

    /// `false` only when a version was determined *and* it is too old. An
    /// unreadable version is treated optimistically so a CLI that changed its
    /// `--version` format does not become unusable.
    public var meetsMinimumVersion: Bool {
        guard let version else { return isInstalled }
        return version >= minimumSupportedVersion
    }

    static func missing(
        cli: CLIIdentifier,
        minimumSupportedVersion: SemanticVersion,
        installHint: String
    ) -> Installation {
        Installation(
            cli: cli,
            executableURL: nil,
            version: nil,
            minimumSupportedVersion: minimumSupportedVersion,
            installHint: installHint
        )
    }
}

extension Installation: CustomStringConvertible {
    public var description: String {
        guard let executableURL else { return "\(cli): not installed" }
        let versionText = version.map(\.description) ?? "unknown version"
        let suffix = meetsMinimumVersion ? "" : " (below minimum \(minimumSupportedVersion))"
        return "\(cli): \(versionText) at \(executableURL.path)\(suffix)"
    }
}
