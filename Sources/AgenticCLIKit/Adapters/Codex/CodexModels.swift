import Foundation

extension Codex {
    /// Models `codex` accepts, maintained by hand.
    ///
    /// # Why this list exists
    ///
    /// `codex` has no non-interactive way to enumerate models: `codex models`
    /// exits 1 with "stdin is not a terminal", and neither `codex --help` nor
    /// `codex exec --help` lists valid values for `--model`. Nothing in the CLI
    /// validates the name either — an unknown model is accepted at launch and
    /// fails later at the API call.
    ///
    /// # Maintaining it
    ///
    /// This list is deliberately short, and short lists here are honest: the
    /// entries below are ones observed in use rather than a published catalogue.
    /// Add cases as OpenAI ships models, and treat
    /// ``Codex/Adapter/configuredModel()`` — which reads the user's own
    /// `config.toml` — as the more reliable signal of what a given machine
    /// actually runs.
    ///
    /// As everywhere else, the list is a convenience, not a constraint:
    ///
    /// ```swift
    /// configuration.model = "gpt-6"   // no library update needed
    /// ```
    ///
    /// Verified against `codex-cli` 0.147.0.
    public enum Model: String, KnownModel {
        case gpt54 = "gpt-5.4"
        case gpt54Codex = "gpt-5.4-codex"

        public static let cli = CLIIdentifier.codex

        /// The fallback when nothing else is known.
        ///
        /// `codex` reads its real default from `$CODEX_HOME/config.toml`, so
        /// prefer ``Codex/Adapter/configuredModel()`` for what a machine will
        /// actually run. Leaving ``RunConfiguration/model`` `nil` sends no model
        /// flag, which lets that configured value win.
        public static let `default` = Model.gpt54

        public var displayName: String {
            switch self {
            case .gpt54: return "GPT-5.4"
            case .gpt54Codex: return "GPT-5.4 Codex"
            }
        }

        public var summary: String? {
            switch self {
            case .gpt54: return "General-purpose default"
            case .gpt54Codex: return "Tuned for coding and agentic work"
            }
        }
    }
}
