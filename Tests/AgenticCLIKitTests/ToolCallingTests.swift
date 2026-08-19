import AgenticCLIKitTesting
import Foundation
import Testing

@testable import AgenticCLIKit

/// The tool from the feature request, kept verbatim so the documented shape and
/// the tested shape cannot drift apart.
struct WeatherTool: AgentTool {
    let name = "getWeather"
    let description = "Retrieve the latest weather information for a city"

    struct Arguments: Decodable, Sendable {
        let city: String
    }

    struct Forecast: Encodable, Sendable {
        let city: String
        let temperature: Int
    }

    let argumentSchema = JSONSchema.object([
        "city": .string("The city to get weather information for"),
    ])

    /// Fixed rather than random: a test that asserts on the answer needs the
    /// same answer every run.
    func call(arguments: Arguments) async throws -> Forecast {
        Forecast(city: arguments.city, temperature: arguments.city == "Boston" ? 71 : 94)
    }
}

private func call(_ tool: String, _ arguments: String) -> ScriptedAgent.Reply {
    let escaped = arguments.replacingOccurrences(of: "\"", with: "\\\"")
    return ScriptedAgent.Reply(
        text: #"{"action":"call","tool":"\#(tool)","arguments":"\#(escaped)","text":""}"#
    )
}

private func final(_ text: String) -> ScriptedAgent.Reply {
    ScriptedAgent.Reply(text: #"{"action":"final","tool":"","arguments":"","text":"\#(text)"}"#)
}

private func makeSession(
    _ agent: ScriptedAgent,
    tools: [any AgentTool] = [WeatherTool()],
    instructions: String? = nil,
    maximumToolRounds: Int = 8
) -> AgentSession {
    AgentSession(
        kit: AgenticCLIKit(agents: [agent]),
        cli: .scripted,
        workingDirectory: URL(fileURLWithPath: "/tmp"),
        tools: tools,
        instructions: instructions,
        maximumToolRounds: maximumToolRounds
    )
}

@Suite("Tool-calling format")
struct ToolCallFormatTests {
    /// Every property required, no nested objects, no unions. Each of those is a
    /// concession to a provider that rejects the alternative — see the type's
    /// own documentation — so a change here is a change to what the CLIs accept.
    @Test("The reply schema is one every provider accepts")
    func schemaIsPortable() throws {
        let decoded = try #require(
            try JSONSerialization.jsonObject(with: try ToolCallFormat.schema.jsonData()) as? [String: Any]
        )

        #expect(decoded["additionalProperties"] as? Bool == false)
        #expect(decoded["required"] as? [String] == ["action", "arguments", "text", "tool"])

        let properties = try #require(decoded["properties"] as? [String: Any])
        let action = try #require(properties["action"] as? [String: Any])
        #expect(action["enum"] as? [String] == ["call", "final"])
        // Arguments travel as a string; a nested object breaks OpenAI's strict
        // schema mode, which is what `codex` enforces.
        #expect((properties["arguments"] as? [String: Any])?["type"] as? String == "string")
    }

    @Test("Parses a call and a final answer")
    func parsesBothActions() throws {
        let called = try ToolCallFormat.parse(
            structuredOutput: nil,
            text: #"{"action":"call","tool":"getWeather","arguments":"{\"city\":\"Boston\"}","text":""}"#
        )
        #expect(called == .call(tool: "getWeather", arguments: Data(#"{"city":"Boston"}"#.utf8)))

        let answered = try ToolCallFormat.parse(
            structuredOutput: nil,
            text: #"{"action":"final","tool":"","arguments":"","text":"Boston"}"#
        )
        #expect(answered == .final(text: "Boston"))
    }

    /// The schema fills unused fields with `""`, so "present" has to mean
    /// "non-empty" — otherwise every answer looks like a call to a tool named "".
    @Test("Empty strings count as absent, not as values")
    func emptyFieldsAreNotValues() throws {
        let reply = try ToolCallFormat.parse(
            structuredOutput: nil,
            text: #"{"action":"final","tool":"","arguments":"","text":"done"}"#
        )
        #expect(reply == .final(text: "done"))
    }

    /// Three of the six CLIs cannot enforce the schema, so the parser has to
    /// survive what a model does to JSON when nothing stops it.
    @Test("Reads the object out of prose and code fences")
    func toleratesWrapping() throws {
        let fenced = """
        Sure — here is my reply:

        ```json
        {"action": "call", "tool": "getWeather", "arguments": "{\\"city\\": \\"Wichita\\"}", "text": ""}
        ```

        Let me know if that works.
        """
        #expect(
            try ToolCallFormat.parse(structuredOutput: nil, text: fenced)
                == .call(tool: "getWeather", arguments: Data(#"{"city":"Wichita"}"#.utf8))
        )
    }

    /// Taking everything between the first `{` and the last `}` would swallow a
    /// closing brace that happens to appear in a trailing sentence.
    @Test("Balances braces rather than spanning the whole string")
    func findsBalancedObject() throws {
        let text = #"{"action":"final","tool":"","arguments":"","text":"ok"} — the } was cosmetic"#
        #expect(try ToolCallFormat.parse(structuredOutput: nil, text: text) == .final(text: "ok"))
    }

    /// A model that sends the object rather than the string means the same
    /// thing, and a run should not fail over the difference.
    @Test("Accepts arguments sent as an object")
    func acceptsObjectArguments() throws {
        let reply = try ToolCallFormat.parse(
            structuredOutput: nil,
            text: #"{"action":"call","tool":"getWeather","arguments":{"city":"Boston"}}"#
        )
        #expect(reply == .call(tool: "getWeather", arguments: Data(#"{"city":"Boston"}"#.utf8)))
    }

    @Test("Prefers the CLI's structured output over its message text")
    func prefersStructuredOutput() throws {
        let reply = try ToolCallFormat.parse(
            structuredOutput: Data(#"{"action":"final","tool":"","arguments":"","text":"schema"}"#.utf8),
            text: #"{"action":"final","tool":"","arguments":"","text":"prose"}"#
        )
        #expect(reply == .final(text: "schema"))
    }

    /// An answer is an answer, even when the model forgets to label it.
    @Test("A reply with text but no action is treated as final")
    func toleratesMissingAction() throws {
        #expect(try ToolCallFormat.parse(structuredOutput: nil, text: #"{"text":"42"}"#) == .final(text: "42"))
    }

    @Test("Refuses replies that name nothing and answer nothing")
    func rejectsEmptyReplies() {
        #expect(throws: AgenticCLIError.self) {
            try ToolCallFormat.parse(structuredOutput: nil, text: "I will look that up for you.")
        }
        #expect(throws: AgenticCLIError.self) {
            try ToolCallFormat.parse(structuredOutput: nil, text: #"{"action":"call","tool":""}"#)
        }
    }

    @Test("The preamble names every tool and its schema")
    func preambleDescribesTools() {
        let preamble = ToolCallFormat.preamble(
            for: [WeatherTool().erased],
            instructions: "Help the person with getting weather information"
        )

        #expect(preamble.hasPrefix("Help the person with getting weather information"))
        #expect(preamble.contains("getWeather"))
        #expect(preamble.contains("Retrieve the latest weather information for a city"))
        #expect(preamble.contains("The city to get weather information for"))
    }
}

@Suite("Tool erasure")
struct AgentToolTests {
    @Test("A typed tool decodes its arguments and encodes its result")
    func erasesTypedTool() async throws {
        let function = WeatherTool().erased

        #expect(function.name == "getWeather")
        let output = try await function.handler(Data(#"{"city":"Boston"}"#.utf8))
        #expect(output == #"{"city":"Boston","temperature":71}"#)
    }

    /// A `String` result is the answer itself; JSON-encoding it would hand the
    /// model a quoted string to unwrap.
    @Test("A String result is returned verbatim")
    func passesStringsThrough() async throws {
        let function = AgentFunction(
            name: "echo",
            description: "Echoes",
            parameters: .object(["text": .string()]),
            decoding: [String: String].self
        ) { $0["text"] ?? "" }

        #expect(try await function.handler(Data(#"{"text":"hi"}"#.utf8)) == "hi")
    }

    @Test("Arguments that do not match the schema fail with a readable reason")
    func reportsUndecodableArguments() async {
        let function = WeatherTool().erased
        await #expect(throws: AgentToolError.self) {
            try await function.handler(Data(#"{"town":"Boston"}"#.utf8))
        }
    }

    @Test("A tool taking no arguments needs no schema")
    func supportsArgumentlessTools() async throws {
        struct Ping: AgentTool {
            let name = "ping"
            let description = "Answers pong"
            func call(arguments: NoArguments) async throws -> String { "pong" }
        }

        let function = Ping().erased
        #expect((function.parameters.jsonObject()["properties"] as? [String: Any])?.isEmpty == true)
        #expect(try await function.handler(Data("{}".utf8)) == "pong")
    }

    @Test("Names the CLIs cannot match are refused before the run")
    func validatesNames() {
        func validate(_ functions: [AgentFunction]) throws {
            try AgentFunction.validate(functions)
        }
        func tool(_ name: String, description: String = "Does a thing") -> AgentFunction {
            AgentFunction(name: name, description: description) { _ in "" }
        }

        #expect(throws: AgenticCLIError.self) { try validate([tool("")]) }
        #expect(throws: AgenticCLIError.self) { try validate([tool("get weather")]) }
        #expect(throws: AgenticCLIError.self) { try validate([tool("get", description: "")]) }
        #expect(throws: AgenticCLIError.self) { try validate([tool("get"), tool("get")]) }
        #expect(throws: Never.self) { try validate([tool("get-weather_2")]) }
    }
}

@Suite("Tool-calling sessions")
struct AgentSessionTests {
    @Test("Runs the tool the agent asks for and feeds the result back")
    func resolvesOneCall() async throws {
        let agent = ScriptedAgent(replies: [
            call("getWeather", #"{"city":"Boston"}"#),
            final("Boston is 71°."),
        ])

        let response = try await makeSession(agent).respond(to: "How warm is Boston?")

        #expect(response.text == "Boston is 71°.")
        #expect(response.rounds == 2)
        #expect(response.toolCalls.map(\.tool) == ["getWeather"])
        #expect(response.toolCalls.first?.output == #"{"city":"Boston","temperature":71}"#)
        #expect(response.toolCalls.first?.isError == false)

        // The second turn has to carry the result, or the agent is answering
        // from memory rather than from the tool.
        let secondPrompt = try #require(agent.prompts.last)
        #expect(secondPrompt.contains("RESULT from tool `getWeather`"))
        #expect(secondPrompt.contains(#""temperature":71"#))
        // …and it has to be a resume, not a fresh conversation.
        #expect(agent.invocations.last?.session != nil)
    }

    @Test("The opening prompt carries the format and the task")
    func opensWithThePreamble() async throws {
        let agent = ScriptedAgent(replies: [final("done")])
        _ = try await makeSession(agent, instructions: "Be brief").respond(to: "Say hello")

        let opening = try #require(agent.prompts.first)
        #expect(opening.hasPrefix("Be brief"))
        #expect(opening.contains("getWeather"))
        #expect(opening.contains("REPLY FORMAT"))
        #expect(opening.hasSuffix("TASK\nSay hello"))
    }

    @Test("A CLI that enforces schemas is given one; one that cannot is not")
    func setsSchemaOnlyWhereItIsEnforced() async throws {
        let enforcing = ScriptedAgent(replies: [final("done")])
        _ = try await makeSession(enforcing).respond(to: "Hello")
        #expect(enforcing.invocations.first?.configuration.outputSchema == ToolCallFormat.schema)

        let lenient = ScriptedAgent(
            replies: [final("done")],
            capabilities: [.prompting, .sessions, .structuredOutput]
        )
        _ = try await makeSession(lenient).respond(to: "Hello")
        #expect(lenient.invocations.first?.configuration.outputSchema == nil)
    }

    /// Naming a tool that does not exist is a mistake the agent can recover
    /// from, so it is told rather than the run being failed.
    @Test("An unknown tool comes back as an error the agent can react to")
    func reportsUnknownTools() async throws {
        let agent = ScriptedAgent(replies: [
            call("getWeatherForecast", "{}"),
            final("Sorry, I used the wrong name."),
        ])

        let response = try await makeSession(agent).respond(to: "How warm is Boston?")

        #expect(response.toolCalls.first?.isError == true)
        #expect(response.toolCalls.first?.output.contains("getWeather") == true)
        #expect(try #require(agent.prompts.last).hasPrefix("ERROR from tool"))
    }

    @Test("A tool that throws reports its message instead of failing the run")
    func reportsThrownToolErrors() async throws {
        struct Failing: AgentTool {
            let name = "lookup"
            let description = "Always fails"
            func call(arguments: NoArguments) async throws -> String {
                throw AgenticCLIError.invalidTool(name: "lookup", reason: "the service is down")
            }
        }

        let agent = ScriptedAgent(replies: [call("lookup", "{}"), final("It is unavailable.")])
        let response = try await makeSession(agent, tools: [Failing()]).respond(to: "Look it up")

        #expect(response.text == "It is unavailable.")
        #expect(response.toolCalls.first?.isError == true)
        #expect(response.toolCalls.first?.output.contains("the service is down") == true)
    }

    /// One correction, then the failure stands: every attempt is billed, and a
    /// model that cannot produce the format twice will not produce it on the
    /// tenth try.
    @Test("An unusable reply earns exactly one correction")
    func repairsOnce() async throws {
        let recovering = ScriptedAgent(replies: [
            ScriptedAgent.Reply(text: "I'll get right on that."),
            final("Boston is warmer."),
        ])
        let response = try await makeSession(recovering).respond(to: "Which is warmer?")
        #expect(response.text == "Boston is warmer.")
        #expect(try #require(recovering.prompts.last).contains("was not usable"))

        let hopeless = ScriptedAgent(replies: [
            ScriptedAgent.Reply(text: "Working on it."),
            ScriptedAgent.Reply(text: "Still working on it."),
        ])
        await #expect(throws: AgenticCLIError.self) {
            try await makeSession(hopeless).respond(to: "Which is warmer?")
        }
    }

    @Test("A model that never answers is stopped at the round limit")
    func stopsAtTheRoundLimit() async throws {
        let agent = ScriptedAgent(replies: Array(
            repeating: call("getWeather", #"{"city":"Boston"}"#),
            count: 4
        ))

        do {
            _ = try await makeSession(agent, maximumToolRounds: 3).respond(to: "Loop forever")
            Issue.record("Expected a refusal")
        } catch let error as AgenticCLIError {
            guard case let .toolCallLimitReached(cli, rounds, calls) = error else {
                Issue.record("Expected .toolCallLimitReached, got \(error)")
                return
            }
            #expect(cli == .scripted)
            #expect(rounds == 3)
            #expect(calls == ["getWeather", "getWeather", "getWeather"])
        }
        // Stopped means stopped: the fourth reply was never asked for.
        #expect(agent.prompts.count == 3)
    }

    /// Without tools there is nothing to negotiate, and imposing the format
    /// would cost a turn and a chance to get the JSON wrong.
    @Test("A session with no tools asks plainly")
    func skipsTheFormatWithoutTools() async throws {
        let agent = ScriptedAgent(replies: [ScriptedAgent.Reply(text: "Hello back.")])
        let response = try await makeSession(agent, tools: []).respond(to: "Say hello")

        #expect(response.text == "Hello back.")
        #expect(response.rounds == 1)
        #expect(agent.prompts == ["Say hello"])
        #expect(agent.invocations.first?.configuration.outputSchema == nil)
    }

    /// Resuming is how a tool result reaches the agent; without it the exchange
    /// cannot happen at all.
    @Test("A CLI that cannot resume is refused up front")
    func requiresSessions() async {
        let agent = ScriptedAgent(replies: [final("never reached")], capabilities: [.prompting])
        do {
            _ = try await makeSession(agent).respond(to: "Hello")
            Issue.record("Expected a refusal")
        } catch let error as AgenticCLIError {
            guard case let .unsupportedCapability(_, capability) = error else {
                Issue.record("Expected .unsupportedCapability, got \(error)")
                return
            }
            #expect(capability.contains(.sessions))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Usage is summed across the rounds a turn cost")
    func combinesUsage() async throws {
        let agent = ScriptedAgent(replies: [
            ScriptedAgent.Reply(
                text: call("getWeather", #"{"city":"Boston"}"#).text,
                usage: UsageInfo(inputTokens: 100, outputTokens: 10, costUSD: 0.01)
            ),
            ScriptedAgent.Reply(
                text: final("Boston is 71°.").text,
                usage: UsageInfo(inputTokens: 150, outputTokens: 20, costUSD: 0.02)
            ),
        ])

        let response = try await makeSession(agent).respond(to: "How warm is Boston?")
        #expect(response.usage?.inputTokens == 250)
        #expect(response.usage?.outputTokens == 30)
        #expect(response.usage?.costUSD == 0.03)
        // A field nobody reported stays unmeasured rather than becoming zero.
        #expect(response.usage?.premiumRequests == nil)
    }

    @Test("A follow-up continues the same conversation")
    func keepsTheSessionAcrossTurns() async throws {
        let agent = ScriptedAgent(replies: [
            final("Boston is 71°."),
            call("getWeather", #"{"city":"Wichita"}"#),
            final("Wichita is warmer."),
        ])
        let session = makeSession(agent)

        _ = try await session.respond(to: "How warm is Boston?")
        let second = try await session.respond(to: "And Wichita?")

        #expect(second.text == "Wichita is warmer.")
        #expect(await session.session?.sessionID == agent.sessionID)
        // Only the opening turn starts a conversation; everything after resumes.
        #expect(agent.invocations.map { $0.session != nil } == [false, true, true])
    }
}
