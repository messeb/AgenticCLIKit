import Foundation

/// Namespace for the OpenAI Codex (`codex`) adapter.
///
/// Verified against `codex-cli` 0.147.0.
public enum Codex {
    /// Sandbox policies `codex exec --sandbox` accepts.
    enum SandboxMode: String {
        case readOnly = "read-only"
        case workspaceWrite = "workspace-write"
        case dangerFullAccess = "danger-full-access"
    }
}

extension Codex {
    /// Translates `codex exec --json` JSONL into ``AgentEvent``s.
    ///
    /// Codex reports completed items rather than token deltas, so this
    /// translator emits ``AgentEvent/assistantMessage(_:)`` and never
    /// ``AgentEvent/assistantTextDelta(_:)``. Callers that render text should
    /// handle both, which is why ``AgentEventStream/textFragments`` does.
    struct Translator: AgentOutputTranslating {
        let workingDirectory: URL
        let resumedSession: SessionReference?

        private var sessionID: String?
        private var assistantText = ""
        private var usage: UsageInfo?
        private var failureMessage: String?
        private var model: String?

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
                return [.diagnostic(line)]
            }

            switch object["type"] as? String {
            case "thread.started":
                guard let id = object["thread_id"] as? String else { return [.raw(data)] }
                sessionID = id
                return [.sessionStarted(makeSessionReference(id: id))]

            case "turn.started":
                return []

            case "item.started", "item.updated", "item.completed":
                let isCompleted = object["type"] as? String == "item.completed"
                guard let item = object["item"] as? [String: Any] else { return [.raw(data)] }
                return translateItem(item, isCompleted: isCompleted, raw: data)

            case "turn.completed":
                usage = Self.parseUsage(object["usage"] as? [String: Any])
                return [.turnCompleted(usage)]

            case "turn.failed":
                let error = object["error"] as? [String: Any]
                failureMessage = error?["message"] as? String ?? "Turn failed"
                return [.raw(data)]

            case "error":
                failureMessage = object["message"] as? String ?? "Codex reported an error"
                return [.raw(data)]

            default:
                return [.raw(data)]
            }
        }

        private mutating func translateItem(
            _ item: [String: Any],
            isCompleted: Bool,
            raw: Data
        ) -> [AgentEvent] {
            let id = item["id"] as? String

            switch item["type"] as? String {
            case "agent_message":
                guard isCompleted, let text = item["text"] as? String, !text.isEmpty else { return [] }
                assistantText += (assistantText.isEmpty ? "" : "\n") + text
                return [.assistantMessage(text)]

            case "reasoning":
                guard let text = item["text"] as? String, !text.isEmpty else { return [] }
                return isCompleted ? [.reasoningDelta(text)] : []

            case "command_execution":
                let command = item["command"] as? String ?? ""
                if isCompleted {
                    let output = item["aggregated_output"] as? String
                    let exitCode = item["exit_code"] as? Int ?? 0
                    return [.toolResult(ToolOutcome(
                        id: id,
                        name: "shell",
                        output: output.map { Data($0.utf8) },
                        isError: exitCode != 0
                    ))]
                }
                return [.toolUseRequested(ToolInvocation(
                    id: id,
                    name: "shell",
                    input: Data(command.utf8),
                    summary: command
                ))]

            case "file_change":
                guard !isCompleted else { return [.toolResult(ToolOutcome(id: id, name: "apply_patch"))] }
                let changes = (item["changes"] as? [[String: Any]])
                    .flatMap { try? JSONSerialization.data(withJSONObject: $0) }
                return [.toolUseRequested(ToolInvocation(id: id, name: "apply_patch", input: changes))]

            case "mcp_tool_call":
                let server = item["server"] as? String ?? "mcp"
                let tool = item["tool"] as? String ?? "tool"
                if isCompleted {
                    return [.toolResult(ToolOutcome(
                        id: id,
                        name: "\(server).\(tool)",
                        isError: (item["status"] as? String) == "failed"
                    ))]
                }
                return [.toolUseRequested(ToolInvocation(id: id, name: "\(server).\(tool)"))]

            case "web_search":
                guard isCompleted else { return [] }
                let query = item["query"] as? String
                return [.toolUseRequested(ToolInvocation(
                    id: id,
                    name: "web_search",
                    input: query.map { Data($0.utf8) },
                    summary: query
                ))]

            case "error":
                let message = item["message"] as? String
                if let message { failureMessage = message }
                return [.diagnostic(message ?? "Codex item error")]

            default:
                return [.raw(raw)]
            }
        }

        static func parseUsage(_ usage: [String: Any]?) -> UsageInfo? {
            guard let usage else { return nil }
            return UsageInfo(
                inputTokens: usage["input_tokens"] as? Int,
                outputTokens: usage["output_tokens"] as? Int,
                cachedInputTokens: usage["cached_input_tokens"] as? Int,
                cacheWriteTokens: usage["cache_write_input_tokens"] as? Int,
                reasoningTokens: usage["reasoning_output_tokens"] as? Int
            )
        }

        private func makeSessionReference(id: String) -> SessionReference {
            if let resumedSession, resumedSession.sessionID == id {
                return resumedSession.touched()
            }
            return SessionReference(
                cli: .codex,
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
            if let failureMessage, assistantText.isEmpty {
                throw Self.mapFailure(
                    exit: exit,
                    standardError: failureMessage,
                    session: resumedSession
                )
            }
            if !exit.isSuccess, assistantText.isEmpty {
                throw Self.mapFailure(exit: exit, standardError: standardError, session: resumedSession)
            }

            return AgentResponse(
                text: assistantText,
                session: sessionID.map(makeSessionReference),
                usage: usage,
                exitCode: exit.code,
                isError: failureMessage != nil || !exit.isSuccess,
                stopReason: failureMessage == nil ? "completed" : "failed",
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
                || message.contains("unauthorized")
                || message.contains("please run `codex login`")
                || message.contains("invalid api key") {
                return .notAuthenticated(.codex, loginCommand: "codex login")
            }
            if let session,
               message.contains("session not found")
                || message.contains("no session")
                || message.contains("failed to find session") {
                return .sessionNotFound(session)
            }
            if message.contains("unexpected argument") || message.contains("unrecognized") {
                return .unsupportedByVersion(
                    .codex,
                    feature: standardError.trimmingCharacters(in: .whitespacesAndNewlines),
                    found: nil
                )
            }
            return .processFailed(.codex, exitCode: exit.code, standardError: standardError)
        }
    }
}
