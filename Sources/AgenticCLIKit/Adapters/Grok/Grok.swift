import Foundation

/// Namespace for xAI's Grok Build CLI (`grok`).
///
/// The adapter uses Grok's documented headless `streaming-json` format. The
/// CLI is fast-moving and its complete event schema is not yet published, so
/// unrecognised events are preserved as raw JSON and the adapter is marked
/// experimental.
public enum Grok {}

extension Grok {
    struct Translator: AgentOutputTranslating {
        let workingDirectory: URL
        let resumedSession: SessionReference?

        private var sessionID: String?
        private var text = ""
        private var usage: UsageInfo?
        private var stopReason: String?
        private var model: String?
        private var failureMessage: String?
        private var structuredOutput: Data?
        private var toolNames: [String: String] = [:]

        init(workingDirectory: URL, resumedSession: SessionReference?) {
            self.workingDirectory = workingDirectory
            self.resumedSession = resumedSession
            sessionID = resumedSession?.sessionID
            model = resumedSession?.model
        }

        mutating func translate(line: String) -> [AgentEvent] {
            guard let data = line.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { return [.diagnostic(line)] }

            var events: [AgentEvent] = []
            if let id = object["sessionId"] as? String, id != sessionID {
                sessionID = id
                events.append(.sessionStarted(sessionReference(id: id)))
            }
            if let selectedModel = object["model"] as? String { model = selectedModel }

            switch object["type"] as? String {
            case "text":
                guard let delta = object["data"] as? String, !delta.isEmpty else { return events }
                text += delta
                events.append(.assistantTextDelta(delta))
            case "thought", "reasoning":
                if let delta = object["data"] as? String, !delta.isEmpty {
                    events.append(.reasoningDelta(delta))
                }
            case "tool_call":
                let id = object["toolCallId"] as? String
                let name = object["toolName"] as? String ?? object["title"] as? String ?? "tool"
                if let id { toolNames[id] = name }
                events.append(.toolUseRequested(ToolInvocation(
                    id: id, name: name, input: jsonData(from: object["rawInput"])
                )))
            case "tool_call_update":
                let id = object["toolCallId"] as? String
                let name = id.flatMap { toolNames[$0] } ?? object["toolName"] as? String
                let status = (object["status"] as? String ?? "").lowercased()
                if status == "denied" || status == "rejected" {
                    events.append(.permissionDenied(tool: name ?? "tool", reason: object["message"] as? String))
                } else if ["completed", "failed", "cancelled"].contains(status) {
                    events.append(.toolResult(ToolOutcome(
                        id: id, name: name, output: jsonData(from: object["rawOutput"]),
                        isError: status != "completed"
                    )))
                }
            case "usage":
                usage = Self.parseUsage(object["usage"] as? [String: Any], model: model)
                events.append(.turnCompleted(usage))
            case "end":
                stopReason = object["stopReason"] as? String
                usage = Self.parseUsage(object["usage"] as? [String: Any], model: model) ?? usage
                if let usage { events.append(.turnCompleted(usage)) }
            case "error":
                failureMessage = object["message"] as? String ?? "grok reported an error"
                events.append(.diagnostic(failureMessage!))
            default:
                // `--json-schema` implies Grok's buffered `json` format. Its
                // final object has `text`, `sessionId`, and `stopReason`, not a
                // streaming event discriminator.
                if absorbBufferedResult(object) {
                    events.append(.assistantMessage(text))
                    if let usage { events.append(.turnCompleted(usage)) }
                } else {
                    events.append(.raw(data))
                }
            }
            return events
        }

        /// Takes the fields of Grok's buffered result object. Returns `false`
        /// when this is not one.
        @discardableResult
        private mutating func absorbBufferedResult(_ object: [String: Any]) -> Bool {
            guard let answer = object["text"] as? String else { return false }
            text = answer
            stopReason = object["stopReason"] as? String ?? stopReason
            usage = Self.parseUsage(object["usage"] as? [String: Any], model: model) ?? usage
            structuredOutput = Data(answer.utf8)
            return true
        }

        static func parseUsage(_ value: [String: Any]?, model: String?) -> UsageInfo? {
            guard let value else { return nil }
            return UsageInfo(
                inputTokens: value["input_tokens"] as? Int,
                outputTokens: value["output_tokens"] as? Int,
                cachedInputTokens: value["cache_read_input_tokens"] as? Int,
                cacheWriteTokens: value["cache_creation_input_tokens"] as? Int,
                reasoningTokens: value["reasoning_tokens"] as? Int,
                model: model
            )
        }

        private func sessionReference(id: String) -> SessionReference {
            if let resumedSession, resumedSession.sessionID == id { return resumedSession.touched() }
            return SessionReference(cli: .grok, sessionID: id, workingDirectory: workingDirectory, model: model)
        }

        mutating func makeResponse(
            exit: ProcessExit, rawOutput: Data, standardError: String, duration: Duration
        ) throws -> AgentResponse {
            if !exit.isSuccess {
                throw AgenticCLIError.processFailed(.grok, exitCode: exit.code,
                    standardError: failureMessage ?? standardError)
            }

            // Grok pretty-prints its buffered `json` result across many lines, so
            // no single line is parseable and nothing reaches the switch above.
            // Reading the whole of stdout is the only way to see that shape — and
            // it carries the session ID, without which the conversation cannot be
            // resumed.
            if text.isEmpty,
               let object = (try? JSONSerialization.jsonObject(with: rawOutput)) as? [String: Any] {
                absorbBufferedResult(object)
                if let id = object["sessionId"] as? String { sessionID = id }
            }

            return AgentResponse(
                text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                session: sessionID.map(sessionReference), usage: usage, exitCode: exit.code,
                isError: failureMessage != nil, stopReason: stopReason, structuredOutput: structuredOutput, rawOutput: rawOutput,
                standardError: standardError, duration: duration
            )
        }
    }
}
