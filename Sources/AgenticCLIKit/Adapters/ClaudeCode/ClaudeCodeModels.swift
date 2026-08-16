import Foundation

extension ClaudeCode {
    /// Models `claude` accepts, maintained by hand.
    ///
    /// # Why this list exists
    ///
    /// `claude` has no command that enumerates models. `claude models` looks like
    /// one, but it is not a subcommand — the word is taken as a *prompt*, so it
    /// spends a billable turn and answers conversationally. Its output cannot be
    /// trusted as a catalogue, so the adapter does not call it.
    ///
    /// # Maintaining it
    ///
    /// Add a case when Anthropic ships a model. Aliases (``opus``, ``sonnet``,
    /// ``fable``) always resolve to the current release of that family and rarely
    /// need touching; the pinned identifiers below do.
    ///
    /// The list is a convenience, never a constraint —
    /// ``RunConfiguration/model`` takes any string, so a model released after
    /// this package was tagged works immediately:
    ///
    /// ```swift
    /// configuration.model = "claude-opus-6"   // no library update needed
    /// ```
    ///
    /// Verified against `claude` 2.1.224.
    public enum Model: String, KnownModel {
        // Aliases — always the latest release of that family.
        /// Most capable widely released model.
        case fable
        /// Balanced default for day-to-day work.
        case opus
        /// Faster and cheaper than Opus, still highly capable.
        case sonnet

        // Pinned identifiers — use when a run must not drift between releases.
        case fable5 = "claude-fable-5"
        case opus5 = "claude-opus-5"
        case sonnet5 = "claude-sonnet-5"
        case haiku45 = "claude-haiku-4-5"
        case opus48 = "claude-opus-4-8"

        public static let cli = CLIIdentifier.claudeCode

        /// What `claude` runs when no model is requested.
        ///
        /// Note that leaving ``RunConfiguration/model`` `nil` does *not* send
        /// this — it sends no model flag at all, so the user's own configured
        /// choice wins. This value only describes what that choice defaults to.
        public static let `default` = Model.opus

        public var displayName: String {
            switch self {
            case .fable: return "Fable (latest)"
            case .opus: return "Opus (latest)"
            case .sonnet: return "Sonnet (latest)"
            case .fable5: return "Claude Fable 5"
            case .opus5: return "Claude Opus 5"
            case .sonnet5: return "Claude Sonnet 5"
            case .haiku45: return "Claude Haiku 4.5"
            case .opus48: return "Claude Opus 4.8"
            }
        }

        public var summary: String? {
            switch self {
            case .fable, .fable5: return "Most capable; deepest reasoning and longest-horizon work"
            case .opus, .opus5: return "Strong general default for coding and agentic work"
            case .sonnet, .sonnet5: return "Balanced speed and capability"
            case .haiku45: return "Fastest and cheapest; simple, high-volume tasks"
            case .opus48: return "Previous Opus generation"
            }
        }

        /// True for the family aliases, which track the latest release.
        public var isAlias: Bool {
            switch self {
            case .fable, .opus, .sonnet: return true
            default: return false
            }
        }
    }
}
