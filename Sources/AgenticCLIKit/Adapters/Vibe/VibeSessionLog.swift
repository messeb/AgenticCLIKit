import Foundation

extension Vibe {
    /// Reads the session log `vibe` writes beside every run.
    ///
    /// # Why a file, and not stdout
    ///
    /// `vibe` streams its transcript as NDJSON but keeps the accounting out of
    /// it: no entry carries token counts, and none carries a price. The numbers
    /// exist — `--max-price` and `--max-tokens` are enforced against them — they
    /// are just written to disk instead of being printed. This reader is the
    /// only filesystem side channel in the package, kept in one file so it is
    /// obvious where it is.
    ///
    /// # Two layouts
    ///
    /// - **Unified Harness (2.26+).** `$VIBE_HOME/logs/session/unified/<id>/`
    ///   is a versioned store. `CURRENT` names the live generation; its
    ///   `projection-state.json` holds the public session snapshot with the
    ///   session's running token totals, and `runtime-state.json` the model it
    ///   ran on. There are no per-turn figures and no prices: a run's usage is
    ///   the change in totals across it, and the price is looked up by model —
    ///   see ``usage(forSessionID:since:)``. Upgrading migrates older sessions
    ///   into this layout.
    /// - **Legacy (2.24–2.25).** `$VIBE_HOME/logs/session/session_<timestamp>_<id>/meta.json`
    ///   carries per-turn tokens, prices, and the step count.
    ///
    /// It serves two features:
    ///
    /// - **Usage.** ``usage(forSessionID:since:)`` reports the tokens and
    ///   dollars for the run that just finished.
    /// - **Turn limits.** Legacy ``Metadata/Stats/steps`` is what `vibe`
    ///   compared `--max-turns` against, so a resumed run adds it to the
    ///   caller's limit. The Unified Harness counts per run and records no
    ///   steps, so the limit passes through.
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
            usage(forSessionID: sessionID, since: nil)
        }

        /// Usage for the run that just finished.
        ///
        /// Under the Unified Harness that is the session's totals minus
        /// `baseline` — the totals read before a resumed run started; `nil` for
        /// a fresh session. Legacy logs record the last turn directly and
        /// ignore `baseline`.
        public func usage(forSessionID sessionID: String, since baseline: TokenTotals?) -> UsageInfo? {
            guard let totals = tokenTotals(forSessionID: sessionID) else {
                return metadata(forSessionID: sessionID)?.lastTurnUsage
            }
            let run = baseline.map(totals.subtracting) ?? totals
            guard run.inputTokens > 0 || run.outputTokens > 0 else { return nil }

            let model = activeModel(forSessionID: sessionID)
            return UsageInfo(
                inputTokens: run.inputTokens,
                outputTokens: run.outputTokens,
                cachedInputTokens: run.cachedInputTokens,
                costUSD: model.flatMap(price(forModel:))?.cost(
                    promptTokens: run.inputTokens,
                    completionTokens: run.outputTokens,
                    cachedTokens: run.cachedInputTokens
                ),
                model: model
            )
        }

        // MARK: Unified Harness

        /// The live generation of a Unified Harness session, as `CURRENT` names it.
        func unifiedGeneration(forSessionID sessionID: String) -> URL? {
            let session = sessionsDirectory
                .appendingPathComponent("unified", isDirectory: true)
                .appendingPathComponent(sessionID, isDirectory: true)
            guard
                let current = readJSON(session.appendingPathComponent("CURRENT")),
                let generation = current["generation"] as? String, !generation.isEmpty
            else { return nil }
            return session
                .appendingPathComponent("generations", isDirectory: true)
                .appendingPathComponent(generation, isDirectory: true)
        }

        /// The session's running token totals, from the public snapshot
        /// (`harness.public-session-state/v1`). `nil` for a legacy session.
        public func tokenTotals(forSessionID sessionID: String) -> TokenTotals? {
            guard
                let generation = unifiedGeneration(forSessionID: sessionID),
                let state = readJSON(generation.appendingPathComponent("projection-state.json")),
                let snapshot = state["snapshot"] as? [String: Any],
                let session = snapshot["session"] as? [String: Any],
                let usage = session["tokenUsage"] as? [String: Any]
            else { return nil }
            return TokenTotals(
                inputTokens: usage["inputTokens"] as? Int ?? 0,
                outputTokens: usage["outputTokens"] as? Int ?? 0,
                cachedInputTokens: usage["cachedInputTokens"] as? Int ?? 0
            )
        }

        /// The model alias a Unified Harness session ran on.
        func activeModel(forSessionID sessionID: String) -> String? {
            guard
                let generation = unifiedGeneration(forSessionID: sessionID),
                let state = readJSON(generation.appendingPathComponent("runtime-state.json")),
                let metadata = state["session_metadata"] as? [String: Any],
                let model = metadata["active_model"] as? String, !model.isEmpty
            else { return nil }
            return model
        }

        /// What `vibe` charges for a model alias.
        ///
        /// `config.toml` first, because that is what the user pinned. Then the
        /// experiment cache: an unpinned `vibe` runs on a default that is routed
        /// remotely, and the cached rollout payload is the only place its price
        /// is written down. The cache is searched for any model definition with
        /// a matching alias rather than by path, so a reshuffled payload still
        /// resolves — and a missing one costs the price, not the tokens.
        func price(forModel alias: String) -> Price? {
            if let toml = try? String(contentsOf: home.appendingPathComponent("config.toml"), encoding: .utf8),
               let price = Configuration.price(forModel: alias, fromTOML: toml) {
                return price
            }
            guard let cache = readJSON(home.appendingPathComponent("experiment_eval_cache.json")) else {
                return nil
            }
            return Price.find(alias: alias, in: cache)
        }

        private func readJSON(_ url: URL) -> [String: Any]? {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }

        /// A session's cumulative tokens, as the Unified Harness records them.
        /// Input includes the cached share.
        public struct TokenTotals: Sendable, Equatable {
            public var inputTokens: Int
            public var outputTokens: Int
            public var cachedInputTokens: Int

            public init(inputTokens: Int, outputTokens: Int, cachedInputTokens: Int) {
                self.inputTokens = inputTokens
                self.outputTokens = outputTokens
                self.cachedInputTokens = cachedInputTokens
            }

            /// The tokens spent since `earlier`, clamped at zero so a store
            /// that was compacted or rewritten never yields negative usage.
            func subtracting(_ earlier: TokenTotals) -> TokenTotals {
                TokenTotals(
                    inputTokens: max(0, inputTokens - earlier.inputTokens),
                    outputTokens: max(0, outputTokens - earlier.outputTokens),
                    cachedInputTokens: max(0, cachedInputTokens - earlier.cachedInputTokens)
                )
            }
        }

        /// Per-million-token rates for one model.
        public struct Price: Sendable, Equatable {
            public var input: Double
            public var output: Double
            /// `nil` bills cached input at ``input``, as `vibe` does.
            public var cachedInput: Double?

            /// `vibe`'s own pricing arithmetic, reproduced so a per-turn figure
            /// is computed the same way as the session total it records.
            ///
            /// Cached prompt tokens are billed at the cached rate when the model
            /// has one, and are clamped to the prompt total: a provider is not
            /// obliged to keep cached a subset of prompt, and an over-count must
            /// not produce a negative price.
            func cost(promptTokens: Int, completionTokens: Int, cachedTokens: Int) -> Double {
                let cached = min(cachedTokens, promptTokens)
                let inputCost = Double(promptTokens - cached) * input + Double(cached) * (cachedInput ?? input)
                return (inputCost + Double(completionTokens) * output) / 1_000_000
            }

            /// The first model definition in `json` whose `alias` matches.
            /// Rollout payloads write the rates as strings, so both forms count.
            static func find(alias: String, in json: Any) -> Price? {
                if let object = json as? [String: Any] {
                    if object["alias"] as? String == alias,
                       let input = number(object["input_price"]),
                       let output = number(object["output_price"]) {
                        let cached = number(object["cached_input_price"]) ?? number(object["cached_price"])
                        return Price(input: input, output: output, cachedInput: cached)
                    }
                    return object.values.lazy.compactMap { find(alias: alias, in: $0) }.first
                }
                if let array = json as? [Any] {
                    return array.lazy.compactMap { find(alias: alias, in: $0) }.first
                }
                return nil
            }

            private static func number(_ value: Any?) -> Double? {
                if let string = value as? String { return Double(string) }
                return (value as? NSNumber)?.doubleValue
            }
        }

        // MARK: Legacy

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

            /// The recorded rates applied with ``Price/cost(promptTokens:completionTokens:cachedTokens:)``.
            func cost(promptTokens: Int, completionTokens: Int, cachedTokens: Int) -> Double? {
                guard let input = stats.inputPricePerMillion,
                      let output = stats.outputPricePerMillion
                else { return nil }
                return Price(input: input, output: output, cachedInput: stats.cachedInputPricePerMillion)
                    .cost(promptTokens: promptTokens, completionTokens: completionTokens, cachedTokens: cachedTokens)
            }
        }
    }
}
