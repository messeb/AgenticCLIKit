import Foundation

extension Copilot {
    /// Models `copilot` accepts, maintained by hand.
    ///
    /// # Where these identifiers come from
    ///
    /// GitHub's [supported models][docs] page lists display names — "GPT-5.4
    /// mini", "Claude Opus 4.8 (fast mode)" — not the strings `--model` takes.
    /// The identifiers below were read from the catalogue the CLI itself
    /// fetches from the Copilot API, so they are exact rather than inferred
    /// from the names. Two would have been guessed wrong:
    /// ``gemini31Pro`` is `gemini-3.1-pro-preview`, and ``maiCode1Flash`` is
    /// `mai-code-1-flash-picker`.
    ///
    /// [docs]: https://docs.github.com/en/copilot/reference/ai-models/supported-models
    ///
    /// # Being listed here does not mean it will run
    ///
    /// Copilot resolves an *available* set per account at launch, and it is
    /// usually much smaller than this list. Each model carries a policy the
    /// account holder has to accept once — until then its state is `disabled`
    /// and `--model` refuses it with
    /// ``AgenticCLIError/unsupportedModel(_:model:reason:)``, whatever the plan
    /// includes. On the machine this was verified against, none of the 51
    /// catalogued models were selectable, while ``auto`` worked throughout.
    ///
    /// So the fix for a refused model is normally "enable that model in Copilot
    /// settings", not "choose a different one" — and ``auto`` is the value that
    /// always works, which is why it is the ``default``.
    ///
    /// # Maintaining it
    ///
    /// Add a case when GitHub adds a model to the page above. As everywhere
    /// else the list is a convenience, never a constraint:
    ///
    /// ```swift
    /// configuration.model = "some-model-shipped-tomorrow"   // no library update needed
    /// ```
    ///
    /// Two models GitHub documents are deliberately absent, because their
    /// identifiers could only have been guessed: **Grok 4.5** and **Grok 4.6**
    /// were not in the fetched catalogue. Pass them as strings if your account
    /// has them.
    ///
    /// Verified against GitHub Copilot CLI 1.0.80.
    public enum Model: String, KnownModel, CaseIterable {
        /// Let Copilot route each turn to a model the account can actually use.
        ///
        /// The only value that cannot go stale, and the only one that worked on
        /// an account with no models enabled.
        case auto

        // MARK: OpenAI

        case gpt5Mini = "gpt-5-mini"
        case gpt53Codex = "gpt-5.3-codex"
        case gpt54 = "gpt-5.4"
        case gpt54Mini = "gpt-5.4-mini"
        case gpt54Nano = "gpt-5.4-nano"
        case gpt55 = "gpt-5.5"
        case gpt56Luna = "gpt-5.6-luna"
        case gpt56Sol = "gpt-5.6-sol"
        case gpt56Terra = "gpt-5.6-terra"

        // MARK: Anthropic

        case claudeFable5 = "claude-fable-5"
        case claudeHaiku45 = "claude-haiku-4.5"
        case claudeOpus45 = "claude-opus-4.5"
        case claudeOpus47 = "claude-opus-4.7"
        case claudeOpus48 = "claude-opus-4.8"
        /// Opus 4.8 with faster output, not a smaller model.
        case claudeOpus48Fast = "claude-opus-4.8-fast"
        case claudeOpus5 = "claude-opus-5"
        case claudeSonnet45 = "claude-sonnet-4.5"
        case claudeSonnet46 = "claude-sonnet-4.6"
        case claudeSonnet5 = "claude-sonnet-5"

        // MARK: Google

        /// Documented as "Gemini 3.1 Pro"; the identifier keeps its
        /// `-preview` suffix.
        case gemini31Pro = "gemini-3.1-pro-preview"
        case gemini35Flash = "gemini-3.5-flash"
        case gemini36Flash = "gemini-3.6-flash"
        case gemini37Flash = "gemini-3.7-flash"

        // MARK: Microsoft

        /// Documented as "MAI-Code-1-Flash"; the identifier carries a
        /// `-picker` suffix the display name gives no hint of.
        case maiCode1Flash = "mai-code-1-flash-picker"
        case maiCode11Flash = "mai-code-1.1-flash"

        // MARK: Moonshot AI

        case kimiK27Code = "kimi-k2.7-code"
        case kimiK3 = "kimi-k3"

        public static let cli = CLIIdentifier.copilot

        /// What `copilot` falls back to, including when a configured model
        /// turns out not to be enabled for the account.
        public static let `default` = Model.auto

        public var displayName: String {
            switch self {
            case .auto: return "Auto"
            case .gpt5Mini: return "GPT-5 mini"
            case .gpt53Codex: return "GPT-5.3-Codex"
            case .gpt54: return "GPT-5.4"
            case .gpt54Mini: return "GPT-5.4 mini"
            case .gpt54Nano: return "GPT-5.4 nano"
            case .gpt55: return "GPT-5.5"
            case .gpt56Luna: return "GPT-5.6 Luna"
            case .gpt56Sol: return "GPT-5.6 Sol"
            case .gpt56Terra: return "GPT-5.6 Terra"
            case .claudeFable5: return "Claude Fable 5"
            case .claudeHaiku45: return "Claude Haiku 4.5"
            case .claudeOpus45: return "Claude Opus 4.5"
            case .claudeOpus47: return "Claude Opus 4.7"
            case .claudeOpus48: return "Claude Opus 4.8"
            case .claudeOpus48Fast: return "Claude Opus 4.8 (fast mode)"
            case .claudeOpus5: return "Claude Opus 5"
            case .claudeSonnet45: return "Claude Sonnet 4.5"
            case .claudeSonnet46: return "Claude Sonnet 4.6"
            case .claudeSonnet5: return "Claude Sonnet 5"
            case .gemini31Pro: return "Gemini 3.1 Pro"
            case .gemini35Flash: return "Gemini 3.5 Flash"
            case .gemini36Flash: return "Gemini 3.6 Flash"
            case .gemini37Flash: return "Gemini 3.7 Flash"
            case .maiCode1Flash: return "MAI-Code-1-Flash"
            case .maiCode11Flash: return "MAI-Code-1.1-Flash"
            case .kimiK27Code: return "Kimi K2.7 Code"
            case .kimiK3: return "Kimi K3"
            }
        }

        public var summary: String? {
            switch self {
            case .auto: return "Routes each turn to a model the account can use"
            default: return vendor.rawValue
            }
        }

        /// Who publishes the model, for grouping a picker.
        public var vendor: Vendor {
            switch self {
            case .auto: return .github
            case .gpt5Mini, .gpt53Codex, .gpt54, .gpt54Mini, .gpt54Nano,
                 .gpt55, .gpt56Luna, .gpt56Sol, .gpt56Terra:
                return .openAI
            case .claudeFable5, .claudeHaiku45, .claudeOpus45, .claudeOpus47,
                 .claudeOpus48, .claudeOpus48Fast, .claudeOpus5,
                 .claudeSonnet45, .claudeSonnet46, .claudeSonnet5:
                return .anthropic
            case .gemini31Pro, .gemini35Flash, .gemini36Flash, .gemini37Flash:
                return .google
            case .maiCode1Flash, .maiCode11Flash:
                return .microsoft
            case .kimiK27Code, .kimiK3:
                return .moonshot
            }
        }

        /// The publisher behind a Copilot model.
        ///
        /// Copilot resells several vendors' models, so a picker that groups by
        /// vendor is far easier to read than one flat list of thirty entries.
        public enum Vendor: String, Sendable, Hashable, CaseIterable {
            case github = "GitHub"
            case openAI = "OpenAI"
            case anthropic = "Anthropic"
            case google = "Google"
            case microsoft = "Microsoft"
            case moonshot = "Moonshot AI"
        }
    }
}

extension Copilot.Model {
    /// The models published by `vendor`, for a grouped picker.
    public static func models(from vendor: Vendor) -> [Copilot.Model] {
        allCases.filter { $0.vendor == vendor }
    }
}
