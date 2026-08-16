import Foundation

extension ClaudeCode {
    /// Maps `claude --output-format json|stream-json` output to ``AgentEvent``s.
    ///
    /// Both formats share the same terminal `type: "result"` object, so one
    /// translator serves the buffered and streaming paths — they cannot report
    /// different session IDs or usage.
    struct Translator: AgentOutputTranslating {
        let workingDirectory: URL
        /// Session we resumed into, when this run is a continuation.
        let resumedSession: SessionReference?

        private var sessionID: String?
        private var model: String?
        private var streamedText = ""
        private var messageText = ""
        private var result: ResultPayload?
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
                // Not JSON: `claude` occasionally prints a plain notice before
                // the stream starts. Surface it rather than dropping it.
                return [.diagnostic(line)]
            }

            var events: [AgentEvent] = []
            if let id = object["session_id"] as? String, id != sessionID {
                sessionID = id
                events.append(.sessionStarted(makeSessionReference(id: id)))
            }

            switch object["type"] as? String {
            case "system":
                if let modelName = object["model"] as? String { model = modelName }
                if object["subtype"] as? String != "init" {
                    events.append(.raw(data))
                }

            case "stream_event":
                events.append(contentsOf: translateStreamEvent(object, raw: data))

            case "assistant":
                events.append(contentsOf: translateAssistantMessage(object, raw: data))

            case "user":
                events.append(contentsOf: translateToolResults(object, raw: data))

            case "result":
                if let payload = try? decoder.decode(ResultPayload.self, from: data) {
                    result = payload
                    events.append(.turnCompleted(payload.makeUsageInfo()))
                } else {
                    events.append(.raw(data))
                }

            default:
                events.append(.raw(data))
            }
            return events
        }

        private mutating func translateStreamEvent(_ object: [String: Any], raw: Data) -> [AgentEvent] {
            guard let event = object["event"] as? [String: Any] else { return [.raw(raw)] }

            switch event["type"] as? String {
            case "content_block_delta":
                guard let delta = event["delta"] as? [String: Any] else { return [.raw(raw)] }
                switch delta["type"] as? String {
                case "text_delta":
                    guard let text = delta["text"] as? String, !text.isEmpty else { return [] }
                    streamedText += text
                    return [.assistantTextDelta(text)]
                case "thinking_delta":
                    guard let text = delta["thinking"] as? String, !text.isEmpty else { return [] }
                    return [.reasoningDelta(text)]
                default:
                    return []
                }

            case "message_start":
                if let message = event["message"] as? [String: Any],
                   let modelName = message["model"] as? String {
                    model = modelName
                }
                return []

            // Structural events carry no information the typed cases need.
            case "content_block_start", "content_block_stop", "message_delta", "message_stop":
                return []

            default:
                return [.raw(raw)]
            }
        }

        private mutating func translateAssistantMessage(_ object: [String: Any], raw: Data) -> [AgentEvent] {
            guard
                let message = object["message"] as? [String: Any],
                let content = message["content"] as? [[String: Any]]
            else { return [.raw(raw)] }

            if let modelName = message["model"] as? String { model = modelName }

            var events: [AgentEvent] = []
            for block in content {
                switch block["type"] as? String {
                case "text":
                    guard let text = block["text"] as? String, !text.isEmpty else { continue }
                    messageText += (messageText.isEmpty ? "" : "\n") + text
                    // With --include-partial-messages the same text already
                    // arrived as deltas; do not emit it twice.
                    if streamedText.isEmpty {
                        events.append(.assistantMessage(text))
                    }

                case "tool_use":
                    let name = block["name"] as? String ?? "unknown"
                    let input = (block["input"] as? [String: Any])
                        .flatMap { try? JSONSerialization.data(withJSONObject: $0) }
                    events.append(.toolUseRequested(
                        ToolInvocation(id: block["id"] as? String, name: name, input: input)
                    ))

                default:
                    continue
                }
            }
            return events
        }

        private func translateToolResults(_ object: [String: Any], raw: Data) -> [AgentEvent] {
            guard
                let message = object["message"] as? [String: Any],
                let content = message["content"] as? [[String: Any]]
            else { return [] }

            return content.compactMap { block in
                guard block["type"] as? String == "tool_result" else { return nil }
                let output: Data?
                switch block["content"] {
                case let text as String:
                    output = Data(text.utf8)
                case let value?:
                    // Not `JSONSerialization` directly: a `null` or a bare
                    // number here raises an ObjC exception that `try?` cannot
                    // catch, which aborts the process.
                    output = jsonData(from: value)
                default:
                    output = nil
                }
                return .toolResult(ToolOutcome(
                    id: block["tool_use_id"] as? String,
                    name: nil,
                    output: output,
                    isError: block["is_error"] as? Bool ?? false
                ))
            }
        }

        private func makeSessionReference(id: String) -> SessionReference {
            if let resumedSession, resumedSession.sessionID == id {
                return resumedSession.touched()
            }
            return SessionReference(
                cli: .claudeCode,
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
            let text = result?.result ?? (streamedText.isEmpty ? messageText : streamedText)

            if let result {
                if result.subtype == "error_max_turns" {
                    throw AgenticCLIError.turnLimitReached(.claudeCode, partialText: text)
                }
                if result.isError, text.isEmpty {
                    throw AgenticCLIError.processFailed(
                        .claudeCode,
                        exitCode: exit.code,
                        standardError: result.errorMessage ?? standardError
                    )
                }
            } else if !exit.isSuccess {
                throw Self.mapFailure(exit: exit, standardError: standardError, session: resumedSession)
            } else if rawOutput.isEmpty {
                throw AgenticCLIError.malformedOutput(reason: "claude produced no output", raw: rawOutput)
            }

            let session = sessionID.map(makeSessionReference)
            return AgentResponse(
                text: text,
                session: session,
                usage: result?.makeUsageInfo(),
                exitCode: exit.code,
                isError: result?.isError ?? !exit.isSuccess,
                stopReason: result?.stopReason ?? result?.subtype,
                structuredOutput: result?.structuredOutput,
                rawOutput: rawOutput,
                standardError: standardError,
                duration: duration
            )
        }

        /// Turns exit codes and stderr prose into typed errors.
        ///
        /// Prose matching is unavoidable here: `claude` uses exit code 1 for
        /// every failure. Matches are kept broad and additive so a reworded
        /// message degrades to ``AgenticCLIError/processFailed(_:exitCode:standardError:)``
        /// rather than misclassifying.
        static func mapFailure(
            exit: ProcessExit,
            standardError: String,
            session: SessionReference?
        ) -> AgenticCLIError {
            let message = standardError.lowercased()

            if message.contains("not logged in")
                || message.contains("authentication")
                || message.contains("invalid api key")
                || message.contains("please run /login")
                || message.contains("oauth token has expired") {
                return .notAuthenticated(.claudeCode, loginCommand: "claude auth login")
            }
            if let session,
               message.contains("no conversation found")
                || message.contains("session not found")
                || message.contains("no such session") {
                return .sessionNotFound(session)
            }
            if message.contains("unknown option") || message.contains("unknown argument") {
                return .unsupportedByVersion(
                    .claudeCode,
                    feature: standardError.trimmingCharacters(in: .whitespacesAndNewlines),
                    found: nil
                )
            }
            return .processFailed(.claudeCode, exitCode: exit.code, standardError: standardError)
        }
    }
}
