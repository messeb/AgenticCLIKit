import Foundation

extension Vibe {
    /// Models `vibe` ships with, maintained by hand.
    ///
    /// # These are aliases, not model names
    ///
    /// `vibe` addresses models by the `alias` in its configuration, not by the
    /// name the provider knows them under: the default entry is named
    /// `mistral-vibe-cli-latest` and aliased `mistral-medium-3.5`, and the alias
    /// is what selects it. Passing the provider's name selects nothing.
    ///
    /// # Selection is an environment variable, and a wrong one is silent
    ///
    /// There is no `--model` flag. The alias goes in `VIBE_ACTIVE_MODEL`, which
    /// overrides `active_model` in `config.toml` for one run. `vibe` resolves an
    /// alias it does not know by **falling back to the default** without saying
    /// so — a run asked to use one model quietly billed on another. So
    /// ``Vibe/Adapter`` checks the requested alias against this list plus the
    /// user's own `config.toml` and throws
    /// ``AgenticCLIError/unsupportedModel(_:model:reason:)`` rather than passing
    /// a value that would be ignored.
    ///
    /// # Maintaining it
    ///
    /// Add a case when Mistral ships one. Custom entries do not need a library
    /// update — an alias defined in the user's `config.toml` is discovered and
    /// accepted.
    ///
    /// Verified against `vibe` 2.24.1.
    public enum Model: String, KnownModel, CaseIterable {
        /// Mistral Medium 3.5, aliased over the rolling `mistral-vibe-cli-latest`
        /// endpoint. Reasons at high effort and accepts images.
        case mistralMedium35 = "mistral-medium-3.5"
        /// The small Devstral, for cheap mechanical work. No reasoning.
        case devstralSmall = "devstral-small"
        /// A model served by a local `llama.cpp` at `127.0.0.1:8080`, priced at
        /// zero because nothing is billed. Present in the default configuration
        /// but only usable when that server is running.
        case local

        public static var cli: CLIIdentifier { .vibe }
        public static var `default`: Self { .mistralMedium35 }

        public var displayName: String {
            switch self {
            case .mistralMedium35: return "Mistral Medium 3.5"
            case .devstralSmall: return "Devstral Small"
            case .local: return "Local (llama.cpp)"
            }
        }

        public var summary: String? {
            switch self {
            case .mistralMedium35:
                return "Default. Vision-capable, high reasoning effort."
            case .devstralSmall:
                return "Cheaper and faster; no reasoning support."
            case .local:
                return "Whatever a local llama.cpp server is serving; needs it running."
            }
        }
    }
}

extension Vibe {
    /// The parts of `vibe`'s `config.toml` this package reads.
    ///
    /// A minimal scanner rather than a TOML parser, for the same reason the
    /// Codex adapter has one: the package takes no dependencies, and two keys do
    /// not justify a parser. It understands what it needs and ignores the rest.
    enum Configuration {
        /// Model aliases defined in a configuration file, in file order.
        ///
        /// Aliases come from `[[models]]` tables; an entry without an `alias`
        /// contributes its `name`, which is what `vibe` falls back to.
        static func modelAliases(fromTOML toml: String) -> [String] {
            var aliases: [String] = []
            var insideModelTable = false
            var pendingName: String?
            var pendingAlias: String?

            func flush() {
                if let alias = pendingAlias ?? pendingName, !aliases.contains(alias) {
                    aliases.append(alias)
                }
                pendingName = nil
                pendingAlias = nil
            }

            for rawLine in toml.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("[") {
                    if insideModelTable { flush() }
                    insideModelTable = line.hasPrefix("[[models]]")
                    continue
                }
                guard insideModelTable, let (key, value) = keyValue(in: line) else { continue }
                switch key {
                case "alias": pendingAlias = value
                case "name": pendingName = value
                default: break
                }
            }
            if insideModelTable { flush() }
            return aliases
        }

        /// The top-level `active_model` value, when one is pinned.
        ///
        /// Only the assignment before the first table header counts: `vibe`
        /// nests per-agent overrides in tables of their own, and those describe
        /// other agents, not this run.
        static func activeModel(fromTOML toml: String) -> String? {
            for rawLine in toml.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("[") { return nil }
                guard let (key, value) = keyValue(in: line), key == "active_model" else { continue }
                return value.isEmpty ? nil : value
            }
            return nil
        }

        /// Splits `key = "value"`, ignoring comments and quoting.
        private static func keyValue(in line: String) -> (key: String, value: String)? {
            guard !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { return nil }
            let key = line[line.startIndex..<equals].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if let comment = value.firstIndex(of: "#"), !value.hasPrefix("\"") {
                value = value[value.startIndex..<comment].trimmingCharacters(in: .whitespaces)
            }
            let unquoted = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return key.isEmpty ? nil : (key, unquoted)
        }
    }
}
