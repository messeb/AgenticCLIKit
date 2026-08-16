import Foundation

/// Identifies a command-line agent supported by the kit.
///
/// The type is open-ended on purpose: adding a new adapter never requires
/// touching the core. Declare a new identifier in an extension and ship it
/// alongside your adapter.
///
/// ```swift
/// extension CLIIdentifier {
///     static let aider = CLIIdentifier("aider")
/// }
/// ```
public struct CLIIdentifier: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    /// Anthropic's Claude Code (`claude`).
    public static let claudeCode = CLIIdentifier("claude-code")
    /// OpenAI's Codex CLI (`codex`).
    public static let codex = CLIIdentifier("codex")
    /// GitHub's Copilot CLI (`copilot`), GitHub's coding agent.
    ///
    /// Not `gh`: that binary manages repositories and takes no prompts.
    public static let copilot = CLIIdentifier("copilot")
    /// Google's Antigravity CLI (`agy`).
    public static let antigravity = CLIIdentifier("antigravity")
}

extension CLIIdentifier: CustomStringConvertible {
    public var description: String { rawValue }
}

extension CLIIdentifier: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self.rawValue = value
    }
}
