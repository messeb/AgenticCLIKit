import Foundation

/// The reply format this package defines for tool calling.
///
/// None of the CLIs can call back into the process that launched them: they
/// reach host code only through MCP, which means a socket, a server, and — for
/// three of the six — a change to the user's own configuration file. So tool
/// calling here is built out of what every one of them already does well:
/// structured output and resumable sessions.
///
/// Each turn the agent answers with one JSON object. Either it asks for a tool:
///
/// ```json
/// {"action": "call", "tool": "getWeather", "arguments": "{\"city\": \"Boston\"}"}
/// ```
///
/// …or it is done:
///
/// ```json
/// {"action": "final", "text": "Boston is the hottest of the three."}
/// ```
///
/// The kit runs the tool, resumes the session with the result, and repeats. A
/// CLI that enforces an output schema natively (``CLICapabilities/nativeOutputSchema``)
/// gets ``schema`` passed to it, so the shape is guaranteed by the provider
/// rather than hoped for; the rest are asked in the prompt and parsed
/// leniently. Either way the format is the same, which is what lets one tool
/// definition work across all six CLIs.
public enum ToolCallFormat {
    /// What the agent must reply with, every turn.
    ///
    /// Four required strings, with `""` for the half that does not apply to this
    /// reply. That shape is deliberate, and both halves of it were measured:
    ///
    /// - `arguments` is a JSON string rather than a nested object because
    ///   OpenAI's strict schemas require `additionalProperties: false` on every
    ///   object, which a free-form argument bag cannot honour — `codex` rejects
    ///   the run outright. It is also how OpenAI's own function calling passes
    ///   arguments, so models are fluent in it.
    /// - Nothing is optional because the same strict mode requires every
    ///   property to appear in `required`. The alternative — nullable unions —
    ///   is not portable across the six providers behind these CLIs, while an
    ///   empty string is.
    ///
    /// The parser is looser than the schema, since three of the six CLIs never
    /// enforce it.
    public static let schema = JSONSchema.object([
        "action": .string(
            "'call' to run one tool, 'final' when you are ready to answer",
            oneOf: ["call", "final"]
        ),
        "tool": .string("Name of the tool to run when action is 'call', otherwise an empty string"),
        "arguments": .string(
            #"Arguments for the tool as a JSON object encoded in a string, e.g. {"city": "Boston"}. "#
                + "An empty string when action is 'final'."
        ),
        "text": .string("The answer for the person when action is 'final', otherwise an empty string"),
    ])

    /// One parsed reply.
    public enum Reply: Sendable, Equatable {
        case call(tool: String, arguments: Data)
        case final(text: String)
    }

    // MARK: - Prompting

    /// The instructions prefixed to the first prompt of a tool-calling run.
    ///
    /// Written as a contract rather than a suggestion: the model has to be told
    /// that the JSON object *is* the reply, not a thing to wrap in prose, or the
    /// first turn comes back as an explanation of what it intends to do.
    static func preamble(for functions: [AgentFunction], instructions: String?) -> String {
        var text = ""
        if let instructions, !instructions.isEmpty {
            text += instructions + "\n\n"
        }

        text += """
        You have access to tools provided by the application that started you. \
        They are the only way to reach its state — do not try to reproduce their \
        results by reading files or running commands.

        TOOLS

        """

        for function in functions {
            let schema = (try? function.parameters.jsonString()) ?? "{}"
            text += "- \(function.name): \(function.description)\n  arguments: \(schema)\n"
        }

        text += """

        REPLY FORMAT

        Every reply is a single JSON object and nothing else. No prose, no \
        Markdown, no code fence.

        Always all four keys. `arguments` is a JSON object encoded as a string. \
        Fields that do not apply are empty strings.

        To run a tool:
        {"action": "call", "tool": "<name>", "arguments": "{\\"key\\": \\"value\\"}", "text": ""}

        To answer:
        {"action": "final", "tool": "", "arguments": "", "text": "<your answer>"}

        Run one tool per reply. After each call you will be given its result and \
        can call another. When you have what you need, answer with 'final'.
        """
        return text
    }

    /// The prompt carrying a tool's result back into the conversation.
    static func resultPrompt(tool: String, output: String, isError: Bool) -> String {
        """
        \(isError ? "ERROR" : "RESULT") from tool `\(tool)`:
        \(output)

        Reply in the same JSON format: call another tool, or answer with 'final'.
        """
    }

    /// The prompt sent when a reply did not parse.
    static func repairPrompt(reason: String) -> String {
        """
        Your last reply was not usable: \(reason)

        Reply with a single JSON object and nothing else — either
        {"action": "call", "tool": "<name>", "arguments": "{…}", "text": ""} or
        {"action": "final", "tool": "", "arguments": "", "text": "<your answer>"}.
        """
    }

    // MARK: - Parsing

    /// Reads one reply out of whatever the CLI produced.
    ///
    /// `structuredOutput` is preferred when the CLI reports one, because that
    /// came out of a schema the provider enforced. The text path exists for the
    /// CLIs that cannot enforce a schema, and has to tolerate what a model does
    /// to JSON when nothing stops it: a code fence around it, a sentence before
    /// it, or a trailing note after it.
    static func parse(structuredOutput: Data?, text: String) throws -> Reply {
        if let structuredOutput,
           let object = (try? JSONSerialization.jsonObject(with: structuredOutput)) as? [String: Any],
           let reply = try? reply(from: object) {
            return reply
        }

        guard let object = firstJSONObject(in: text) else {
            throw AgenticCLIError.toolCallProtocolViolation(
                reason: "the reply contained no JSON object",
                text: text
            )
        }
        return try reply(from: object)
    }

    private static func reply(from object: [String: Any]) throws -> Reply {
        let action = (object["action"] as? String)?.lowercased()
        // The schema fills unused fields with empty strings, so "present" has to
        // mean "non-empty" — otherwise every final answer looks like a call to a
        // tool named "".
        let tool = nonEmpty(object["tool"]) ?? nonEmpty(object["name"])
        let text = nonEmpty(object["text"])

        // A model that answers without naming an action has still answered;
        // failing a run over that formality helps nobody.
        if action == "final" || (action == nil && tool == nil) {
            guard let text else {
                throw AgenticCLIError.toolCallProtocolViolation(
                    reason: "a 'final' reply carried no text",
                    text: describe(object)
                )
            }
            return .final(text: text)
        }

        guard let tool else {
            throw AgenticCLIError.toolCallProtocolViolation(
                reason: "a 'call' reply named no tool",
                text: describe(object)
            )
        }
        return .call(tool: tool, arguments: argumentData(from: object["arguments"]))
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Normalises whichever of the two argument encodings arrived.
    ///
    /// The schema asks for a JSON string, but a model that never saw the schema
    /// will often send the object itself, and one that did will occasionally
    /// send it anyway. Both mean the same thing, so both are accepted; anything
    /// else becomes an empty argument object and fails on the tool's own decode,
    /// where the error message can name the field.
    static func argumentData(from value: Any?) -> Data {
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return Data("{}".utf8) }
            // Re-encode through the object so a string of malformed JSON is
            // caught here rather than inside the tool.
            if let object = firstJSONObject(in: trimmed),
               let data = try? JSONSerialization.data(withJSONObject: object) {
                return data
            }
            return Data(trimmed.utf8)
        }
        if let object = value as? [String: Any],
           let data = try? JSONSerialization.data(withJSONObject: object) {
            return data
        }
        return Data("{}".utf8)
    }

    private static func describe(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return "\(object)"
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Finds the first balanced JSON object in a string.
    ///
    /// Scanning for balanced braces rather than taking everything between the
    /// first `{` and the last `}`: a reply that ends with a sentence containing a
    /// brace would otherwise swallow it and fail to parse.
    static func firstJSONObject(in text: String) -> [String: Any]? {
        let characters = Array(text)
        var index = 0

        while index < characters.count {
            guard characters[index] == "{" else {
                index += 1
                continue
            }

            var depth = 0
            var isInString = false
            var isEscaped = false

            for end in index..<characters.count {
                let character = characters[end]

                if isEscaped {
                    isEscaped = false
                } else if character == "\\" && isInString {
                    isEscaped = true
                } else if character == "\"" {
                    isInString.toggle()
                } else if !isInString {
                    if character == "{" { depth += 1 }
                    if character == "}" {
                        depth -= 1
                        if depth == 0 {
                            let candidate = String(characters[index...end])
                            if let object = (try? JSONSerialization.jsonObject(with: Data(candidate.utf8)))
                                as? [String: Any] {
                                return object
                            }
                            break
                        }
                    }
                }
            }
            index += 1
        }
        return nil
    }
}
