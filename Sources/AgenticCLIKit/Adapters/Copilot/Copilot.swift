import Foundation

/// Namespace for the GitHub Copilot CLI (`copilot`) adapter.
///
/// This is GitHub's *agent*, and the one to reach for when you want "the
/// GitHub CLI agent". `gh` is a different binary from the same vendor: it
/// manages repositories — issues, pull requests, releases — takes no prompts,
/// and is not an agentic CLI, so this package does not wrap it.
///
/// Verified against GitHub Copilot CLI 1.0.80.
public enum Copilot {
    /// Tool-permission patterns, in `copilot`'s own `kind(argument)` grammar.
    ///
    /// `copilot` is the only adapter here with a real per-tool permission
    /// language, and denials always beat allowances — including
    /// `--allow-all-tools`. That is what makes a genuine read-only posture
    /// expressible rather than approximated.
    public enum Permission {
        /// Any shell command.
        public static let shell = "shell"
        /// Any file creation or modification outside the shell tool.
        public static let write = "write"

        /// A specific shell command, e.g. `shell(git)`.
        public static func shell(_ command: String) -> String { "shell(\(command))" }
        /// A shell command and its subcommands, e.g. `shell(git:*)`.
        public static func shellPrefix(_ command: String) -> String { "shell(\(command):*)" }
        /// Writes to a specific path.
        public static func write(_ path: String) -> String { "write(\(path))" }
    }
}

extension Copilot {
    /// Translates `copilot --output-format json` (JSONL) into ``AgentEvent``s.
    ///
    /// The wire format nests everything under `data`, and carries both
    /// incremental `assistant.message_delta` events and a consolidated
    /// `assistant.message`. The terminal `result` object holds the session ID,
    /// exit code, and usage.
    struct Translator: AgentOutputTranslating {
        let workingDirectory: URL
        let resumedSession: SessionReference?
        /// The identifier handed to `--session-id`, so the session is known
        /// before the run ends rather than only from the final event.
        let expectedSessionID: String?

        private var sessionID: String?
        private var model: String?
        private var streamedText = ""
        /// The most recent non-empty `assistant.message`.
        ///
        /// One run can span several turns — narrate, call a tool, then answer —
        /// and only the last message is the answer. Concatenating them would put
        /// "Reading the file to extract its second line." in front of "beta".
        private var lastMessageText = ""
        private var usage: UsageInfo?
        private var result: ResultPayload?
        /// `tool.execution_complete` identifies its call but does not name the
        /// tool again, so the name is kept from the matching start event.
        private var toolNames: [String: String] = [:]
        /// Summed across turns; Copilot reports these per message.
        private var outputTokens: Int?
        private var failureMessage: String?
        private let decoder = JSONDecoder()

        init(
            workingDirectory: URL,
            resumedSession: SessionReference? = nil,
            expectedSessionID: String? = nil
        ) {
            self.workingDirectory = workingDirectory
            self.resumedSession = resumedSession
            self.expectedSessionID = expectedSessionID
            self.sessionID = resumedSession?.sessionID ?? expectedSessionID
        }

        mutating func translate(line: String) -> [AgentEvent] {
            guard
                let data = line.data(using: .utf8),
                let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else {
                return [.diagnostic(line)]
            }

            let payload = object["data"] as? [String: Any] ?? [:]

            switch object["type"] as? String {
            case "assistant.message_delta":
                guard let delta = payload["deltaContent"] as? String, !delta.isEmpty else { return [] }
                streamedText += delta
                return [.assistantTextDelta(delta)]

            case "assistant.message":
                return translateAssistantMessage(payload, raw: data)

            case "session.auto_mode_resolved", "session.tools_updated", "model.call_start":
                // These name the model that will actually serve the turn, which
                // matters when the caller asked for `auto`.
                if let chosen = payload["chosenModel"] as? String ?? payload["model"] as? String {
                    model = chosen
                }
                return []

            case "session.usage_checkpoint":
                usage = Self.parseUsage(payload, model: model)
                return [.turnCompleted(usage)]

            case "result":
                guard let decoded = try? decoder.decode(ResultPayload.self, from: data) else {
                    return [.raw(data)]
                }
                result = decoded
                var events: [AgentEvent] = []
                if let id = decoded.sessionID, id != sessionID {
                    sessionID = id
                    events.append(.sessionStarted(makeSessionReference(id: id)))
                }
                return events

            case "error", "session.error":
                failureMessage = payload["message"] as? String
                    ?? object["message"] as? String
                    ?? "copilot reported an error"
                return [.diagnostic(failureMessage ?? "")]

            // Setup chatter: MCP servers connecting, skills loading, the echo of
            // our own prompt, and the per-character `tool_call_delta` stream —
            // which arrives once per JSON fragment of the arguments and would
            // bury a consumer in events that say nothing `tool.execution_start`
            // does not say once, in full.
            case "session.mcp_servers_loaded", "session.mcp_server_status_changed",
                 "mcp.tools.list_changed", "session.skills_loaded",
                 "session.custom_agents_updated", "user.message",
                 "assistant.turn_start", "assistant.turn_end",
                 "assistant.message_start", "assistant.idle",
                 "assistant.tool_call_delta", "assistant.reasoning":
                return []

            default:
                return translateToolEvent(object, payload: payload, raw: data)
            }
        }

        private mutating func translateAssistantMessage(
            _ payload: [String: Any],
            raw: Data
        ) -> [AgentEvent] {
            if let chosen = payload["model"] as? String { model = chosen }

            // Copilot bills in credits, but still reports output tokens per
            // message. A run can span several turns, so they accumulate.
            if let tokens = payload["outputTokens"] as? Int {
                outputTokens = (outputTokens ?? 0) + tokens
            }

            guard let text = payload["content"] as? String, !text.isEmpty else { return [] }
            lastMessageText = text
            // The same text already arrived as deltas; do not emit it twice.
            // `toolRequests` is ignored here for the same reason: the tool calls
            // it names are reported in full by `tool.execution_start`.
            return streamedText.isEmpty ? [.assistantMessage(text)] : []
        }

        /// Maps the `tool.*` family.
        ///
        /// `execution_start` and `execution_complete` are matched by name
        /// because they are the two this adapter is verified against; anything
        /// else in the family is matched structurally, so a `tool.` event added
        /// by a later release degrades to a sensible event instead of `.raw`.
        private mutating func translateToolEvent(
            _ object: [String: Any],
            payload: [String: Any],
            raw: Data
        ) -> [AgentEvent] {
            guard let type = object["type"] as? String, type.hasPrefix("tool.") else {
                return [.raw(raw)]
            }

            let id = payload["toolCallId"] as? String ?? payload["id"] as? String
            let name = payload["toolName"] as? String
                ?? payload["name"] as? String
                ?? id.flatMap { toolNames[$0] }
                ?? "tool"
            if let id { toolNames[id] = name }

            switch type {
            case "tool.execution_start":
                // A tool called with no arguments prints `null` here, which
                // `JSONSerialization` refuses with an ObjC exception rather than
                // a Swift error — uncatchable, and fatal.
                let input = jsonData(from: payload["arguments"])
                return [.toolUseRequested(ToolInvocation(id: id, name: name, input: input))]

            case "tool.execution_complete":
                let succeeded = payload["success"] as? Bool ?? true
                let output = jsonData(from: payload["result"])
                return [.toolResult(ToolOutcome(
                    id: id, name: name, output: output, isError: !succeeded
                ))]

            default:
                if type.contains("denied") || type.contains("rejected") {
                    return [.permissionDenied(tool: name, reason: payload["reason"] as? String)]
                }
                if type.contains("complete") || type.contains("end") {
                    return [.toolResult(ToolOutcome(id: id, name: name))]
                }
                return [.toolUseRequested(ToolInvocation(id: id, name: name))]
            }
        }

        /// Copilot bills in premium requests and AI credits, not tokens, so the
        /// normalised ``UsageInfo`` carries what it does report and leaves the
        /// token fields empty rather than inventing them.
        static func parseUsage(_ payload: [String: Any], model: String?) -> UsageInfo {
            var usage = UsageInfo(model: model)
            if let nanoCredits = payload["totalNanoAiu"] as? Int {
                // AI credits arrive in nano-units; report them as whole credits.
                usage.costUSD = nil
                usage.aiCredits = Double(nanoCredits) / 1_000_000_000
            }
            if let premium = payload["totalPremiumRequests"] as? Int {
                usage.premiumRequests = premium
            }
            return usage
        }

        private func makeSessionReference(id: String) -> SessionReference {
            if let resumedSession, resumedSession.sessionID == id {
                return resumedSession.touched()
            }
            return SessionReference(
                cli: .copilot,
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
            let text = (lastMessageText.isEmpty ? streamedText : lastMessageText)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let reportedExitCode = result?.exitCode ?? exit.code

            if text.isEmpty, reportedExitCode != 0 || !exit.isSuccess {
                throw Self.mapFailure(
                    exit: ProcessExit(code: reportedExitCode),
                    standardError: failureMessage ?? standardError,
                    session: resumedSession
                )
            }
            if result == nil, !exit.isSuccess {
                throw Self.mapFailure(exit: exit, standardError: standardError, session: resumedSession)
            }

            // The checkpoint carries the billing units, the result the durations;
            // neither is a superset, so both go in.
            var mergedUsage: UsageInfo?
            if usage != nil || result?.usage != nil || outputTokens != nil {
                var merged = usage ?? UsageInfo()
                if let final = result?.makeUsageInfo() {
                    merged.premiumRequests = final.premiumRequests ?? merged.premiumRequests
                    merged.duration = final.duration ?? merged.duration
                }
                merged.model = merged.model ?? model
                merged.outputTokens = merged.outputTokens ?? outputTokens
                mergedUsage = merged
            }

            return AgentResponse(
                text: text,
                session: sessionID.map(makeSessionReference),
                usage: mergedUsage,
                exitCode: reportedExitCode,
                isError: reportedExitCode != 0,
                stopReason: reportedExitCode == 0 ? "completed" : "failed",
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

            if message.contains("not authenticated")
                || message.contains("authentication")
                || message.contains("unauthorized")
                || message.contains("please run `copilot login`")
                || message.contains("bad credentials") {
                return .notAuthenticated(.copilot, loginCommand: "copilot login")
            }
            if let session,
               message.contains("session not found")
                || message.contains("no session")
                || message.contains("unknown session") {
                return .sessionNotFound(session)
            }
            // `Error: Model "x" from --model flag is not available.`
            if message.contains("from --model flag is not available")
                || (message.contains("model") && message.contains("is not available")) {
                return .unsupportedModel(
                    .copilot,
                    model: Self.quotedModelName(in: standardError) ?? "unknown",
                    reason: "the model is not enabled for the signed-in account — each "
                        + "Copilot model carries terms that have to be accepted once, in "
                        + "GitHub's Copilot settings, before --model will take it"
                )
            }
            if message.contains("unknown option") || message.contains("unknown command") {
                return .unsupportedByVersion(
                    .copilot,
                    feature: standardError.trimmingCharacters(in: .whitespacesAndNewlines),
                    found: nil
                )
            }
            return .processFailed(.copilot, exitCode: exit.code, standardError: standardError)
        }

        /// The model name out of `Model "gpt-5-mini" from --model flag …`.
        static func quotedModelName(in message: String) -> String? {
            guard let open = message.firstIndex(of: "\"") else { return nil }
            let rest = message[message.index(after: open)...]
            guard let close = rest.firstIndex(of: "\"") else { return nil }
            let name = String(rest[..<close])
            return name.isEmpty ? nil : name
        }
    }

    /// The terminal `result` object of a `--output-format json` run.
    public struct ResultPayload: Decodable, Sendable {
        public let sessionID: String?
        public let exitCode: Int32
        public let usage: Usage?

        private enum CodingKeys: String, CodingKey {
            case sessionID = "sessionId"
            case exitCode
            case usage
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
            exitCode = try container.decodeIfPresent(Int32.self, forKey: .exitCode) ?? 0
            usage = try container.decodeIfPresent(Usage.self, forKey: .usage)
        }

        public struct Usage: Decodable, Sendable {
            public let premiumRequests: Int?
            public let totalApiDurationMs: Int?
            public let sessionDurationMs: Int?
        }

        func makeUsageInfo() -> UsageInfo? {
            guard let usage else { return nil }
            var info = UsageInfo(duration: usage.totalApiDurationMs.map { .milliseconds($0) })
            info.premiumRequests = usage.premiumRequests
            return info
        }
    }
}
