import Foundation

extension Codex {
    /// Reads the token totals `codex` keeps in its rollout log.
    ///
    /// # Why
    ///
    /// `turn.completed` on a resumed thread carries the *thread's* running
    /// total rather than the turn's usage — the third short reply in a thread
    /// reports three replies' worth of tokens. Verified on 0.147 and 0.162. Read as-is, every resume
    /// re-bills the whole conversation, and a tool-calling session that sums
    /// its rounds counts the opening turn once per round.
    ///
    /// The rollout at `$CODEX_HOME/sessions/<yyyy>/<mm>/<dd>/rollout-<timestamp>-<thread>.jsonl`
    /// records the same running total in each `token_count` event. Read before
    /// a resume, it is the baseline; the turn is the reported total minus it.
    ///
    /// The subtraction only happens when the reported usage *is* the rollout's
    /// new total. A release that starts reporting the turn alone would never
    /// match, so its figures would pass through untouched, and a missing or
    /// unreadable rollout costs the correction, never the run.
    struct Rollout: Sendable {
        /// `$CODEX_HOME`, or `~/.codex`.
        let home: URL

        static func resolvedHome(environment: [String: String]) -> URL {
            if let override = environment["CODEX_HOME"], !override.isEmpty {
                return URL(fileURLWithPath: override)
            }
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex", isDirectory: true)
        }

        /// The thread's running total, from the last `token_count` event.
        func totals(forThreadID threadID: String) -> UsageInfo? {
            guard
                let url = file(forThreadID: threadID),
                let contents = try? String(contentsOf: url, encoding: .utf8)
            else { return nil }

            for line in contents.split(separator: "\n").reversed() where line.contains("\"token_count\"") {
                guard
                    let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                    let payload = object["payload"] as? [String: Any],
                    payload["type"] as? String == "token_count",
                    let info = payload["info"] as? [String: Any],
                    let total = info["total_token_usage"] as? [String: Any]
                else { continue }
                return Translator.parseUsage(total)
            }
            return nil
        }

        /// The rollout for a thread. Named by the thread ID's suffix, under a
        /// date the caller does not know, so the tree is searched.
        func file(forThreadID threadID: String) -> URL? {
            let suffix = "-\(threadID).jsonl"
            guard let files = FileManager.default.enumerator(
                at: home.appendingPathComponent("sessions", isDirectory: true),
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { return nil }

            for case let url as URL in files where url.lastPathComponent.hasSuffix(suffix) {
                return url
            }
            return nil
        }

        /// The usage of the turn that just ran.
        ///
        /// `reported` is what `turn.completed` said; `baseline` the total read
        /// before the turn. Only a report equal to the rollout's current total
        /// is a running total, and only then is the baseline subtracted.
        func turnUsage(reported: UsageInfo, baseline: UsageInfo?, threadID: String) -> UsageInfo {
            guard
                let baseline,
                let current = totals(forThreadID: threadID),
                Self.sameCounts(current, reported)
            else { return reported }

            var turn = reported
            turn.inputTokens = Self.difference(reported.inputTokens, baseline.inputTokens)
            turn.outputTokens = Self.difference(reported.outputTokens, baseline.outputTokens)
            turn.cachedInputTokens = Self.difference(reported.cachedInputTokens, baseline.cachedInputTokens)
            turn.cacheWriteTokens = Self.difference(reported.cacheWriteTokens, baseline.cacheWriteTokens)
            turn.reasoningTokens = Self.difference(reported.reasoningTokens, baseline.reasoningTokens)
            return turn
        }

        private static func sameCounts(_ lhs: UsageInfo, _ rhs: UsageInfo) -> Bool {
            lhs.inputTokens == rhs.inputTokens
                && lhs.outputTokens == rhs.outputTokens
                && lhs.cachedInputTokens == rhs.cachedInputTokens
        }

        /// Clamped at zero, so a rewritten log never yields negative usage.
        private static func difference(_ total: Int?, _ earlier: Int?) -> Int? {
            guard let total else { return nil }
            return max(0, total - (earlier ?? 0))
        }
    }
}
