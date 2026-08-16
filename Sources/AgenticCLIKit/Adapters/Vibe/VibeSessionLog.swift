import Foundation

extension Vibe {
    /// Reads the session log `vibe` writes beside every run.
    ///
    /// # Why a file, and not stdout
    ///
    /// `vibe` streams its transcript as NDJSON but keeps the accounting out of
    /// it: no entry carries token counts, and none carries a price. The numbers
    /// exist — `--max-price` and `--max-tokens` are enforced against them — they
    /// are just written to `$VIBE_HOME/logs/session/session_<timestamp>_<id>/meta.json`
    /// instead of being printed. This reader is the only filesystem side channel
    /// in the package, kept in one file so it is obvious where it is.
    ///
    /// It serves two features:
    ///
    /// - **Usage.** ``usage(forSessionID:)`` reports the tokens and dollars for
    ///   the turn that just finished.
    /// - **Turn limits.** ``Metadata/Stats/steps`` is what `vibe` compares
    ///   `--max-turns` against, so a resumed run adds it to the caller's limit
    ///   rather than passing the number through.
    ///
    /// Everything here degrades to `nil`: a user who set `session_logging` off
    /// gets runs without usage, never a failing run.
    public struct SessionLog: Sendable {
        /// `vibe`'s home directory — `$VIBE_HOME`, or `~/.vibe`.
        public let home: URL

        public init(home: URL) {
            self.home = home
        }

        /// Resolves `$VIBE_HOME` the way `vibe` itself does.
        public static func resolvedHome(environment: [String: String]) -> URL {
            if let override = environment[Vibe.homeVariable], !override.isEmpty {
                return URL(fileURLWithPath: override)
            }
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".vibe", isDirectory: true)
        }

        var sessionsDirectory: URL {
            home
                .appendingPathComponent("logs", isDirectory: true)
                .appendingPathComponent("session", isDirectory: true)
        }

        /// The log directory for a session, if one was written.
        ///
        /// Directories are named `session_<yyyyMMdd>_<HHmmss>_<first 8 characters
        /// of the session ID>`, so a session is found by suffix. The timestamp
        /// sorts lexicographically, which is why the newest match is simply the
        /// last one — it matters when a session ID prefix repeats across days.
        public func directory(forSessionID sessionID: String) -> URL? {
            let suffix = "_" + String(sessionID.prefix(8))
            let contents = try? FileManager.default.contentsOfDirectory(
                at: sessionsDirectory,
                includingPropertiesForKeys: nil
            )
            return contents?
                .filter { $0.lastPathComponent.hasSuffix(suffix) }
                .max { $0.lastPathComponent < $1.lastPathComponent }
        }

        /// The parsed `meta.json` for a session, or `nil` when there is none.
        public func metadata(forSessionID sessionID: String) -> Metadata? {
            guard
                let directory = directory(forSessionID: sessionID),
                let data = try? Data(contentsOf: directory.appendingPathComponent("meta.json"))
            else { return nil }
            return try? JSONDecoder().decode(Metadata.self, from: data)
        }

        /// Usage for the most recent turn of a session.
        public func usage(forSessionID sessionID: String) -> UsageInfo? {
            metadata(forSessionID: sessionID)?.lastTurnUsage
        }

        /// How many steps a session has already taken, for offsetting
        /// `--max-turns`. `nil` when no log was written.
        public func steps(forSessionID sessionID: String) -> Int? {
            metadata(forSessionID: sessionID)?.stats.steps
        }

        /// The parts of `meta.json` this package uses.
        ///
        /// Decoding is deliberately partial: the file also holds the full
        /// configuration, the resolved system prompt, and the tool schemas, none
        /// of which are this package's business.
        public struct Metadata: Decodable, Sendable {
            public let sessionID: String
            public let stats: Stats
            /// The model alias the session ran on, from the recorded configuration.
            public let model: String?

            private enum CodingKeys: String, CodingKey {
                case sessionID = "session_id"
                case stats
                case config
            }

            private enum ConfigurationKeys: String, CodingKey {
                case activeModel = "active_model"
            }

            public init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID) ?? ""
                stats = try container.decode(Stats.self, forKey: .stats)

                let configuration = try? container.nestedContainer(
                    keyedBy: ConfigurationKeys.self,
                    forKey: .config
                )
                let active = try? configuration?.decodeIfPresent(String.self, forKey: .activeModel)
                model = (active?.isEmpty == false) ? active : nil
            }

            /// Tokens, prices, and counters, as `vibe` records them.
            public struct Stats: Decodable, Sendable {
                /// Model round trips taken by the session so far.
                ///
                /// This is the quantity `--max-turns` is compared against —
                /// `vibe` stops a run when `steps - 1 >= max_turns` — and it
                /// counts the *whole* session, which is why a resumed run needs
                /// this number to mean anything by "two more turns".
                public let steps: Int
                public let lastTurnPromptTokens: Int
                public let lastTurnCompletionTokens: Int
                public let lastTurnCachedTokens: Int
                public let lastTurnDuration: Double?
                public let sessionPromptTokens: Int
                public let sessionCompletionTokens: Int
                public let sessionCachedTokens: Int
                public let inputPricePerMillion: Double?
                public let outputPricePerMillion: Double?
                public let cachedInputPricePerMillion: Double?

                private enum CodingKeys: String, CodingKey {
                    case steps
                    case lastTurnPromptTokens = "last_turn_prompt_tokens"
                    case lastTurnCompletionTokens = "last_turn_completion_tokens"
                    case lastTurnCachedTokens = "last_turn_cached_tokens"
                    case lastTurnDuration = "last_turn_duration"
                    case sessionPromptTokens = "session_prompt_tokens"
                    case sessionCompletionTokens = "session_completion_tokens"
                    case sessionCachedTokens = "session_cached_tokens"
                    case inputPricePerMillion = "input_price_per_million"
                    case outputPricePerMillion = "output_price_per_million"
                    case cachedInputPricePerMillion = "cached_input_price_per_million"
                }

                public init(from decoder: any Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    steps = try container.decodeIfPresent(Int.self, forKey: .steps) ?? 0
                    lastTurnPromptTokens = try container
                        .decodeIfPresent(Int.self, forKey: .lastTurnPromptTokens) ?? 0
                    lastTurnCompletionTokens = try container
                        .decodeIfPresent(Int.self, forKey: .lastTurnCompletionTokens) ?? 0
                    lastTurnCachedTokens = try container
                        .decodeIfPresent(Int.self, forKey: .lastTurnCachedTokens) ?? 0
                    lastTurnDuration = try container
                        .decodeIfPresent(Double.self, forKey: .lastTurnDuration)
                    sessionPromptTokens = try container
                        .decodeIfPresent(Int.self, forKey: .sessionPromptTokens) ?? 0
                    sessionCompletionTokens = try container
                        .decodeIfPresent(Int.self, forKey: .sessionCompletionTokens) ?? 0
                    sessionCachedTokens = try container
                        .decodeIfPresent(Int.self, forKey: .sessionCachedTokens) ?? 0
                    inputPricePerMillion = try container
                        .decodeIfPresent(Double.self, forKey: .inputPricePerMillion)
                    outputPricePerMillion = try container
                        .decodeIfPresent(Double.self, forKey: .outputPricePerMillion)
                    cachedInputPricePerMillion = try container
                        .decodeIfPresent(Double.self, forKey: .cachedInputPricePerMillion)
                }
            }

            /// Usage for the turn that just finished.
            public var lastTurnUsage: UsageInfo? {
                guard stats.lastTurnPromptTokens > 0 || stats.lastTurnCompletionTokens > 0 else {
                    return nil
                }
                return UsageInfo(
                    inputTokens: stats.lastTurnPromptTokens,
                    outputTokens: stats.lastTurnCompletionTokens,
                    cachedInputTokens: stats.lastTurnCachedTokens,
                    costUSD: cost(
                        promptTokens: stats.lastTurnPromptTokens,
                        completionTokens: stats.lastTurnCompletionTokens,
                        cachedTokens: stats.lastTurnCachedTokens
                    ),
                    model: model,
                    duration: stats.lastTurnDuration.map(Duration.seconds)
                )
            }

            /// Usage for the session as a whole, for a caller that wants the
            /// running total rather than the last turn.
            public var sessionUsage: UsageInfo? {
                guard stats.sessionPromptTokens > 0 || stats.sessionCompletionTokens > 0 else {
                    return nil
                }
                return UsageInfo(
                    inputTokens: stats.sessionPromptTokens,
                    outputTokens: stats.sessionCompletionTokens,
                    cachedInputTokens: stats.sessionCachedTokens,
                    costUSD: cost(
                        promptTokens: stats.sessionPromptTokens,
                        completionTokens: stats.sessionCompletionTokens,
                        cachedTokens: stats.sessionCachedTokens
                    ),
                    model: model
                )
            }

            /// `vibe`'s own pricing arithmetic, reproduced so a per-turn figure
            /// is computed the same way as the session total it records.
            ///
            /// Cached prompt tokens are billed at the cached rate when the model
            /// has one, and are clamped to the prompt total: a provider is not
            /// obliged to keep cached a subset of prompt, and an over-count must
            /// not produce a negative price.
            func cost(promptTokens: Int, completionTokens: Int, cachedTokens: Int) -> Double? {
                guard let inputPrice = stats.inputPricePerMillion,
                      let outputPrice = stats.outputPricePerMillion
                else { return nil }

                let cached = min(cachedTokens, promptTokens)
                let cachedPrice = stats.cachedInputPricePerMillion ?? inputPrice
                let inputCost = Double(promptTokens - cached) * inputPrice + Double(cached) * cachedPrice
                let outputCost = Double(completionTokens) * outputPrice
                return (inputCost + outputCost) / 1_000_000
            }
        }
    }
}
