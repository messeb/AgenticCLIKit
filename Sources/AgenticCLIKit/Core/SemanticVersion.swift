import Foundation

/// A semantic version, parsed leniently from whatever a CLI prints for `--version`.
///
/// Real CLIs decorate their version output (`"2.1.224 (Claude Code)"`,
/// `"codex-cli 0.147.0"`, `"gh version 2.97.0 (2026-07-31)"`), so
/// ``init(parsingFirstMatchIn:)`` scans for the first version-shaped token
/// instead of demanding a clean string.
public struct SemanticVersion: Hashable, Sendable, Codable {
    public let major: Int
    public let minor: Int
    public let patch: Int
    /// Dot-separated prerelease identifiers, e.g. `["beta", "1"]` for `1.0.0-beta.1`.
    public let prereleaseIdentifiers: [String]
    /// Build metadata; ignored for ordering, per semver.
    public let buildMetadata: String?

    public init(
        _ major: Int,
        _ minor: Int = 0,
        _ patch: Int = 0,
        prereleaseIdentifiers: [String] = [],
        buildMetadata: String? = nil
    ) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prereleaseIdentifiers = prereleaseIdentifiers
        self.buildMetadata = buildMetadata
    }

    /// Parses a strict `major.minor[.patch][-prerelease][+build]` string.
    public init?(_ string: String) {
        var remainder = Substring(string.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !remainder.isEmpty else { return nil }

        var build: String?
        if let plus = remainder.firstIndex(of: "+") {
            build = String(remainder[remainder.index(after: plus)...])
            remainder = remainder[..<plus]
        }

        var prerelease: [String] = []
        if let hyphen = remainder.firstIndex(of: "-") {
            prerelease = remainder[remainder.index(after: hyphen)...]
                .split(separator: ".")
                .map(String.init)
            remainder = remainder[..<hyphen]
        }

        let numbers = remainder.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(numbers.count) else { return nil }
        let parsed = numbers.compactMap { Int($0) }
        guard parsed.count == numbers.count else { return nil }

        self.major = parsed[0]
        self.minor = parsed[1]
        self.patch = parsed.count > 2 ? parsed[2] : 0
        self.prereleaseIdentifiers = prerelease
        self.buildMetadata = build
    }

    /// Finds the first version-shaped token anywhere in `text`.
    ///
    /// Tolerates the decoration real CLIs emit around their version number.
    public init?(parsingFirstMatchIn text: String) {
        let pattern = #"\d+\.\d+(\.\d+)?(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard
            let match = regex.firstMatch(in: text, range: range),
            let matched = Range(match.range, in: text),
            let version = SemanticVersion(String(text[matched]))
        else { return nil }
        self = version
    }

    /// True when this version is a prerelease of `major.minor.patch`.
    public var isPrerelease: Bool { !prereleaseIdentifiers.isEmpty }
}

extension SemanticVersion: Comparable {
    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }

        // A version with a prerelease sorts before the corresponding release.
        switch (lhs.isPrerelease, rhs.isPrerelease) {
        case (false, false): return false
        case (true, false): return true
        case (false, true): return false
        case (true, true): break
        }

        for (left, right) in zip(lhs.prereleaseIdentifiers, rhs.prereleaseIdentifiers) {
            if left == right { continue }
            switch (Int(left), Int(right)) {
            case let (leftNumber?, rightNumber?): return leftNumber < rightNumber
            case (_?, nil): return true        // numeric identifiers sort before alphanumeric
            case (nil, _?): return false
            case (nil, nil): return left < right
            }
        }
        return lhs.prereleaseIdentifiers.count < rhs.prereleaseIdentifiers.count
    }
}

extension SemanticVersion: LosslessStringConvertible {
    public var description: String {
        var text = "\(major).\(minor).\(patch)"
        if !prereleaseIdentifiers.isEmpty {
            text += "-" + prereleaseIdentifiers.joined(separator: ".")
        }
        if let buildMetadata {
            text += "+" + buildMetadata
        }
        return text
    }
}

