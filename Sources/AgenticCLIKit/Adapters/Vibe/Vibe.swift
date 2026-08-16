import Foundation

extension CLIIdentifier {
    /// Mistral's Vibe CLI (`vibe`).
    public static let vibe = CLIIdentifier("vibe")
}

/// Namespace for the Mistral Vibe CLI (`vibe`) adapter.
///
/// `vibe` is the only CLI here that limits a run by turns, and one of two that
/// report a dollar figure — but it reports it in a file rather than on stdout,
/// which is what ``Vibe/SessionLog`` exists for.
///
/// Three of its behaviours shape this adapter:
///
/// - **Nothing runs without `--trust`.** A non-interactive `vibe` in an
///   untrusted directory stops at a trust prompt on a stdin that is closed, so
///   every run this adapter builds passes the flag.
/// - **`--max-turns` counts the whole session**, not this run, so resuming
///   needs an offset. See ``Vibe/SessionLog/Metadata/Stats/steps``.
/// - **The model is an environment variable**, not a flag, and an unknown one
///   is ignored rather than refused. See ``Vibe/Model``.
///
/// Verified against `vibe` 2.24.1.
public enum Vibe {
    /// The name `vibe` uses for its home directory environment variable.
    static let homeVariable = "VIBE_HOME"
    /// The configuration field `vibe` reads the active model alias from, and
    /// the environment variable that overrides it.
    static let modelVariable = "VIBE_ACTIVE_MODEL"

    /// Tool names, for ``PermissionPolicy/allowingTools(allowed:denied:)``.
    ///
    /// `vibe`'s `--enabled-tools` and `--disabled-tools` take exact names, glob
    /// patterns, or a regular expression behind a `re:` prefix, and in
    /// programmatic mode an `--enabled-tools` list disables everything it does
    /// not name. That makes an allowlist real enforcement rather than a request,
    /// which is why ``PermissionPolicy/readOnly`` is built from one.
    ///
    /// The names below are the built-in tools `vibe` 2.24.1 offers. MCP tools
    /// are named `{server}_{tool}` and are matched by the same patterns.
    public enum Tool {
        public static let bash = "bash"
        public static let edit = "edit"
        public static let grep = "grep"
        public static let readFile = "read_file"
        public static let skill = "skill"
        public static let task = "task"
        public static let todo = "todo"
        public static let webFetch = "web_fetch"
        public static let webSearch = "web_search"
        public static let writeFile = "write_file"

        /// Tools that only observe: no writes, no shell, no side effects on the
        /// machine.
        ///
        /// This is what ``PermissionPolicy/readOnly`` allows. A tool `vibe` adds
        /// in a later release is *not* in this list, so it stays disabled until
        /// this package is updated — the safe direction for a list that can go
        /// stale.
        public static let readOnly = [readFile, grep, webFetch, webSearch, todo, skill, task]

        /// A regular expression, in the `re:` form `vibe` expects.
        ///
        /// ```swift
        /// Vibe.Tool.matching("^serena_.*$")   // "re:^serena_.*$"
        /// ```
        public static func matching(_ regularExpression: String) -> String {
            "re:\(regularExpression)"
        }
    }

    /// The marker `vibe` wraps around the reason a turn stopped early.
    ///
    /// It arrives twice — once as the text of a final assistant message, once as
    /// a bare line on stdout that is not JSON at all — so both paths have to
    /// recognise it.
    static let stopEventPrefix = "<vibe_stop_event>"
    static let stopEventSuffix = "</vibe_stop_event>"

    /// Extracts the reason out of `<vibe_stop_event>…</vibe_stop_event>`.
    static func stopReason(in text: String) -> String? {
        guard
            let open = text.range(of: stopEventPrefix),
            let close = text.range(of: stopEventSuffix, range: open.upperBound..<text.endIndex)
        else { return nil }
        let reason = String(text[open.upperBound..<close.lowerBound])
        return reason.isEmpty ? nil : reason
    }

    /// The text with any stop-event marker removed.
    static func strippingStopEvent(from text: String) -> String {
        guard let open = text.range(of: stopEventPrefix) else { return text }
        let tail = text.range(of: stopEventSuffix, range: open.upperBound..<text.endIndex)
        var stripped = text
        stripped.removeSubrange(open.lowerBound..<(tail?.upperBound ?? text.endIndex))
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension Vibe {
    /// Translates `vibe --output streaming` (NDJSON) into ``AgentEvent``s.
    ///
    /// Every line is one *entry* in the session transcript, tagged with a
    /// `type`, and every entry carries the `sessionId` — so the session is known
    /// from the first line of a fresh run rather than only at the end.
    ///
    /// Two properties of the format drive the design:
    ///
    /// - **Entries are settled when they arrive.** A tool `effect` is emitted
    ///   once, already carrying its result, so a single entry produces both
    ///   ``AgentEvent/toolUseRequested(_:)`` and ``AgentEvent/toolResult(_:)``.
    ///   Assistant messages arrive whole for the same reason: there are no token
    ///   deltas to forward.
    /// - **A resumed run replays the whole transcript first.** Everything before
    ///   the `checkpoint` entry is history that already happened, and emitting it
    ///   would make a caller see the previous answer as part of this turn. The
    ///   checkpoint is the boundary, so history is suppressed until it arrives.
    struct Translator: AgentOutputTranslating {
        let workingDirectory: URL
        let resumedSession: SessionReference?
        /// Reads usage out of `vibe`'s session log once the process has exited.
        /// A closure rather than the reader itself, so tests can supply usage
        /// without a filesystem.
        let usageProvider: @Sendable (String) -> UsageInfo?

        private var sessionID: String?
        private var model: String?
        /// The most recent non-empty assistant message.
        ///
        /// A run spans several entries — reason, call a tool, reason again,
        /// answer — and only the last message is the answer.
        private var lastMessageText = ""
        /// Set while a resumed run is replaying the transcript that already
        /// existed, before the resume checkpoint.
        private var isReplayingHistory: Bool
        private var stopReason: String?
        private var failureMessage: String?

        init(
            workingDirectory: URL,
            resumedSession: SessionReference? = nil,
            usageProvider: @escaping @Sendable (String) -> UsageInfo? = { _ in nil }
        ) {
            self.workingDirectory = workingDirectory
            self.resumedSession = resumedSession
            self.usageProvider = usageProvider
            self.sessionID = resumedSession?.sessionID
            self.model = resumedSession?.model
            self.isReplayingHistory = resumedSession != nil
        }

        mutating func translate(line: String) -> [AgentEvent] {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return [] }

            guard
                let data = trimmed.data(using: .utf8),
                let entry = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else {
                // `vibe` prints the stop event as a bare line as well as inside
                // the final message. It is the one non-JSON line the format
                // produces, and it is meaning, not noise.
                if let reason = Vibe.stopReason(in: trimmed) {
                    stopReason = reason
                    return [.diagnostic(reason)]
                }
                return [.diagnostic(trimmed)]
            }

            var events: [AgentEvent] = []
            if let id = entry["sessionId"] as? String, id != sessionID {
                sessionID = id
                events.append(.sessionStarted(makeSessionReference(id: id)))
            }

            let type = entry["type"] as? String
            // The checkpoint ends the replay; it is also the only entry worth
            // emitting while history is still being replayed.
            if type == "checkpoint" {
                isReplayingHistory = false
                let message = entry["message"] as? String ?? "checkpoint"
                events.append(.diagnostic(message))
                return events
            }
            guard !isReplayingHistory else { return events }

            switch type {
            case "message":
                events += translateMessage(entry)
            case "reasoning":
                if let text = entry["text"] as? String, !text.isEmpty {
                    events.append(.reasoningDelta(text))
                }
            case "effect":
                events += translateEffect(entry)
            case "callback":
                events += translateCallback(entry)
            case "error":
                let message = entry["message"] as? String ?? "vibe reported an error"
                failureMessage = message
                events.append(.diagnostic(message))
            default:
                events.append(.raw(data))
            }
            return events
        }

        /// Assistant messages, which arrive whole.
        ///
        /// A stop event — turn limit, price limit, token limit — is delivered as
        /// the text of a final assistant message rather than as its own entry,
        /// so it is pulled out here and the remaining text kept as the answer.
        private mutating func translateMessage(_ entry: [String: Any]) -> [AgentEvent] {
            guard entry["role"] as? String == "assistant" else { return [] }

            let text = (entry["content"] as? [[String: Any]] ?? [])
                .compactMap { $0["text"] as? String }
                .joined()
            guard !text.isEmpty else { return [] }

            if let reason = Vibe.stopReason(in: text) {
                stopReason = reason
            }
            let answer = Vibe.strippingStopEvent(from: text)
            guard !answer.isEmpty else { return [] }

            lastMessageText = answer
            return [.assistantMessage(answer)]
        }

        /// Tool calls. One entry, already settled, so both halves are emitted.
        private func translateEffect(_ entry: [String: Any]) -> [AgentEvent] {
            let detail = entry["detail"] as? [String: Any] ?? [:]
            let name = detail["toolName"] as? String ?? entry["title"] as? String ?? "tool"
            let id = entry["id"] as? String
            // `input` is nullable for every effect kind `vibe` defines — a tool
            // call that carries no arguments prints `"input": null` — and the
            // generic kind types it as any JSON value, so it can be a scalar.
            // Handing either to `JSONSerialization` directly aborts the process.
            let input = jsonData(from: detail["input"])

            var events: [AgentEvent] = [
                .toolUseRequested(ToolInvocation(id: id, name: name, input: input)),
            ]

            guard let state = entry["state"] as? [String: Any] else { return events }
            let status = state["status"] as? String ?? "completed"
            // `cancelled` is what a denied tool looks like from here: `vibe`
            // cancels the call rather than failing it. The `callback` entry
            // carries the denial itself, so this stays a result.
            // `output` is nullable too — a cancelled or failed effect has none —
            // and the running text is the fallback when it does.
            let output = jsonData(from: state["output"])
                ?? (state["outputText"] as? String).map { Data($0.utf8) }
            events.append(.toolResult(ToolOutcome(
                id: id,
                name: name,
                output: output,
                isError: status != "completed"
            )))
            return events
        }

        /// Approval requests. Non-interactive runs answer them by denying, and a
        /// denial is the reason a turn stops without doing the work.
        private func translateCallback(_ entry: [String: Any]) -> [AgentEvent] {
            let detail = entry["detail"] as? [String: Any] ?? [:]
            guard detail["kind"] as? String == "approval" else { return [] }

            let effect = detail["effect"] as? [String: Any] ?? [:]
            let tool = effect["toolName"] as? String ?? "tool"
            let decision = ((entry["state"] as? [String: Any])?["output"] as? [String: Any])
                .flatMap { $0["decision"] as? [String: Any] }
                .flatMap { $0["type"] as? String }

            guard decision == "deny" || decision == "cancel_turn" else { return [] }
            let reason = (detail["requiredPermissions"] as? [[String: Any]] ?? [])
                .compactMap { $0["label"] as? String }
                .first
            return [.permissionDenied(tool: tool, reason: reason)]
        }

        private func makeSessionReference(id: String) -> SessionReference {
            if let resumedSession, resumedSession.sessionID == id {
                return resumedSession.touched()
            }
            return SessionReference(
                cli: .vibe,
                sessionID: id,
                workingDirectory: workingDirectory,
                model: model
            )
        }

        mutating func makeResponse(
            exit: ProcessExit,
            rawOutput: Data,
            standardError: String,
            duration: Duration
        ) throws -> AgentResponse {
            let text = lastMessageText.trimmingCharacters(in: .whitespacesAndNewlines)

            // A run stopped by its turn limit exits non-zero, so the stop reason
            // is read before the exit code — otherwise the specific error would
            // be reported as a generic process failure. The caller asked for the
            // limit, so whatever the turn produced travels with the error rather
            // than being returned as if it were a finished answer.
            if let stopReason, stopReason.lowercased().contains("turn limit") {
                throw AgenticCLIError.turnLimitReached(.vibe, partialText: text)
            }
            if !exit.isSuccess {
                throw Self.mapFailure(
                    exit: exit,
                    standardError: failureMessage ?? standardError,
                    session: resumedSession
                )
            }

            var usage = sessionID.flatMap(usageProvider)
            if usage != nil, usage?.duration == nil {
                usage?.duration = duration
            }
            model = usage?.model ?? model

            return AgentResponse(
                text: text,
                session: sessionID.map(makeSessionReference),
                usage: usage,
                exitCode: exit.code,
                isError: false,
                stopReason: stopReason ?? "completed",
                rawOutput: rawOutput,
                standardError: standardError,
                duration: duration
            )
        }

        static func mapFailure(
            exit: ProcessExit,
            standardError: String,
            session: SessionReference?
        ) -> AgenticCLIError {
            let message = standardError.lowercased()

            if let session, message.contains("session not found") {
                return .sessionNotFound(session)
            }
            if message.contains("api key")
                || message.contains("mistral_api_key")
                || message.contains("unauthorized")
                || message.contains("401") {
                return .notAuthenticated(.vibe, loginCommand: "vibe --setup")
            }
            // argparse: `vibe: error: unrecognized arguments: --nope`, and
            // `invalid choice` for a value a newer release would accept.
            if message.contains("unrecognized arguments") || message.contains("invalid choice") {
                return .unsupportedByVersion(
                    .vibe,
                    feature: standardError.trimmingCharacters(in: .whitespacesAndNewlines),
                    found: nil
                )
            }
            return .processFailed(.vibe, exitCode: exit.code, standardError: standardError)
        }
    }
}
