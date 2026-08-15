import Foundation

/// Namespace for the Antigravity (`agy`) adapter.
///
/// Verified against `agy` 1.0.16. Note that `agy --help` prints a *shorter*
/// flag list than `agy help`; the structured-output flags this adapter depends
/// on (`--output-format`, `--mode`) appear only in the latter.
public enum Antigravity {}

extension Antigravity {
    /// Translates `agy --output-format stream-json` into ``AgentEvent``s.
    ///
    /// The wire format is unlike the others: a single `step_update` event type
    /// carrying a `step_type` discriminator, with assistant text arriving as
    /// `text_delta` on `agent_response` steps.
    struct Translator: AgentOutputTranslating {
        let workingDirectory: URL
        let resumedSession: SessionReference?

        private var sessionID: String?
        private var streamedText = ""
        private var usage: UsageInfo?
        private var result: ResultPayload?
        private var activeToolSteps: [Int: String] = [:]
        private let decoder = JSONDecoder()

        init(workingDirectory: URL, resumedSession: SessionReference? = nil) {
            self.workingDirectory = workingDirectory
            self.resumedSession = resumedSession
            self.sessionID = resumedSession?.sessionID
        }

        mutating func translate(line: String) -> [AgentEvent] {
            guard
                let data = line.data(using: .utf8),
                let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else {
                // `--output-format text` and stray notices land here.
                return [.diagnostic(line)]
            }

            var events: [AgentEvent] = []
            if let id = conversationID(in: object), id != sessionID {
                sessionID = id
                events.append(.sessionStarted(makeSessionReference(id: id)))
            }

            // `--output-format json` prints one bare result object with no
            // `event` wrapper; `stream-json` wraps it. Accept both.
            if object["event"] == nil, object["status"] != nil || object["conversation_id"] != nil {
                guard
                    let payloadData = try? JSONSerialization.data(withJSONObject: object),
                    let decoded = try? decoder.decode(ResultPayload.self, from: payloadData)
                else {
                    return events + [.raw(data)]
                }
                result = decoded
                usage = decoded.makeUsageInfo()
                events.append(.turnCompleted(usage))
                return events
            }

            switch object["event"] as? String {
            case "init":
                return events

            case "step_update":
                guard let step = object["step_update"] as? [String: Any] else { return events + [.raw(data)] }
                events += translateStep(step, raw: data)
                return events

            case "result":
                guard
                    let payload = object["result"],
                    let payloadData = try? JSONSerialization.data(withJSONObject: payload),
                    let decoded = try? decoder.decode(ResultPayload.self, from: payloadData)
                else {
                    return events + [.raw(data)]
                }
                result = decoded
                usage = decoded.makeUsageInfo()
                events.append(.turnCompleted(usage))
                return events

            default:
                return events + [.raw(data)]
            }
        }

        private func conversationID(in object: [String: Any]) -> String? {
            if let id = object["conversation_id"] as? String { return id }
            for value in object.values {
                if let nested = value as? [String: Any], let id = nested["conversation_id"] as? String {
                    return id
                }
            }
            return nil
        }

        private mutating func translateStep(_ step: [String: Any], raw: Data) -> [AgentEvent] {
            let stepType = step["step_type"] as? String ?? "unknown"
            let state = step["state"] as? String ?? ""
            let index = step["step_index"] as? Int ?? -1

            if let stepUsage = Self.parseUsage(step["usage"] as? [String: Any]) {
                usage = stepUsage
            }

            switch stepType {
            case "agent_response":
                guard let delta = step["text_delta"] as? String, !delta.isEmpty else { return [] }
                streamedText += delta
                return [.assistantTextDelta(delta)]

            case "thinking", "reasoning":
                guard let delta = step["text_delta"] as? String, !delta.isEmpty else { return [] }
                return [.reasoningDelta(delta)]

            case "user_input", "checkpoint", "unknown":
                return []

            default:
                // Tool-shaped steps: the CLI's vocabulary here is still moving,
                // so match structurally rather than enumerating names.
                let name = step["tool_name"] as? String ?? step["name"] as? String ?? stepType
                if state == "DONE" {
                    let wasActive = activeToolSteps.removeValue(forKey: index) != nil
                    guard wasActive else { return [.raw(raw)] }
                    return [.toolResult(ToolOutcome(
                        id: String(index),
                        name: name,
                        output: (step["text_delta"] as? String).map { Data($0.utf8) },
                        isError: (step["error"] as? String) != nil
                    ))]
                }
                activeToolSteps[index] = name
                return [.toolUseRequested(ToolInvocation(
                    id: String(index),
                    name: name,
                    summary: step["text_delta"] as? String
                ))]
            }
        }

        static func parseUsage(_ usage: [String: Any]?) -> UsageInfo? {
            guard let usage else { return nil }
            return UsageInfo(
                inputTokens: usage["input_tokens"] as? Int,
                outputTokens: usage["output_tokens"] as? Int,
                cachedInputTokens: usage["cache_read_tokens"] as? Int,
                reasoningTokens: usage["thinking_tokens"] as? Int
            )
        }

        private func makeSessionReference(id: String) -> SessionReference {
            if let resumedSession, resumedSession.sessionID == id {
                return resumedSession.touched()
            }
            return SessionReference(cli: .antigravity, sessionID: id, workingDirectory: workingDirectory)
        }

        mutating func makeResponse(
            exit: ProcessExit,
            rawOutput: Data,
            standardError: String,
            duration: Duration
        ) throws -> AgentResponse {
            let text = (result?.response ?? streamedText)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if let result, result.status.uppercased() != "SUCCESS", text.isEmpty {
                throw Self.mapFailure(
                    exit: exit,
                    standardError: standardError.isEmpty ? result.status : standardError,
                    session: resumedSession
                )
            }
            if result == nil, !exit.isSuccess {
                throw Self.mapFailure(exit: exit, standardError: standardError, session: resumedSession)
            }

            return AgentResponse(
                text: text,
                session: sessionID.map(makeSessionReference),
                usage: result?.makeUsageInfo() ?? usage,
                exitCode: exit.code,
                isError: !exit.isSuccess || (result.map { $0.status.uppercased() != "SUCCESS" } ?? false),
                stopReason: result?.status,
                structuredOutput: result?.structuredOutput,
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

            if message.contains("not logged in")
                || message.contains("unauthenticated")
                || message.contains("authentication")
                || message.contains("sign in") {
                return .notAuthenticated(.antigravity, loginCommand: "agy")
            }
            if let session,
               message.contains("conversation not found") || message.contains("no conversation") {
                return .sessionNotFound(session)
            }
            if message.contains("flag provided but not defined") {
                return .unsupportedByVersion(
                    .antigravity,
                    feature: standardError.trimmingCharacters(in: .whitespacesAndNewlines),
                    found: nil
                )
            }
            return .processFailed(.antigravity, exitCode: exit.code, standardError: standardError)
        }
    }

    /// The `result` object from `--output-format json` and the final
    /// `stream-json` event. Both carry the same shape.
    public struct ResultPayload: Decodable, Sendable {
        public let conversationID: String?
        public let status: String
        public let response: String?
        public let durationSeconds: Double?
        public let numTurns: Int?
        public let usage: TokenUsage?
        /// Populated when the run used `--json-schema`. Essential here: `agy`
        /// puts prose *and* the JSON in `response`, so parsing the text would
        /// hand back the prose.
        public let structuredOutput: Data?

        private enum CodingKeys: String, CodingKey {
            case conversationID = "conversation_id"
            case status
            case response
            case durationSeconds = "duration_seconds"
            case numTurns = "num_turns"
            case usage
            case structuredOutput = "structured_output"
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            conversationID = try container.decodeIfPresent(String.self, forKey: .conversationID)
            status = try container.decodeIfPresent(String.self, forKey: .status) ?? "UNKNOWN"
            response = try container.decodeIfPresent(String.self, forKey: .response)
            durationSeconds = try container.decodeIfPresent(Double.self, forKey: .durationSeconds)
            numTurns = try container.decodeIfPresent(Int.self, forKey: .numTurns)
            usage = try container.decodeIfPresent(TokenUsage.self, forKey: .usage)
            structuredOutput = try container.decodeIfPresent(JSONPassthrough.self, forKey: .structuredOutput)?.data
        }

        public struct TokenUsage: Decodable, Sendable {
            public let inputTokens: Int?
            public let outputTokens: Int?
            public let thinkingTokens: Int?
            public let cacheReadTokens: Int?
            public let totalTokens: Int?

            private enum CodingKeys: String, CodingKey {
                case inputTokens = "input_tokens"
                case outputTokens = "output_tokens"
                case thinkingTokens = "thinking_tokens"
                case cacheReadTokens = "cache_read_tokens"
                case totalTokens = "total_tokens"
            }
        }

        func makeUsageInfo() -> UsageInfo? {
            guard usage != nil || numTurns != nil else { return nil }
            return UsageInfo(
                inputTokens: usage?.inputTokens,
                outputTokens: usage?.outputTokens,
                cachedInputTokens: usage?.cacheReadTokens,
                reasoningTokens: usage?.thinkingTokens,
                turns: numTurns,
                duration: durationSeconds.map { .seconds($0) }
            )
        }
    }
}
