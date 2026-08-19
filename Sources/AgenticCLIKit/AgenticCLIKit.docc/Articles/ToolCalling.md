# Tool calling

Let the agent call back into your app, on every supported CLI.

## Overview

Write a tool the way Foundation Models has you write one: a name, a description,
a typed `Arguments`, and a `call` that returns something `Encodable`.

```swift
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

    func call(arguments: Arguments) async throws -> Forecast {
        Forecast(city: arguments.city, temperature: try await Weather.temperature(in: arguments.city))
    }
}

let session = AgentSession(
    cli: .claudeCode,
    workingDirectory: repositoryURL,
    tools: [WeatherTool()],
    instructions: "Help the person with getting weather information"
)

let response = try await session.respond(to: "Is it hotter in Boston, Wichita, or Pittsburgh?")
response.text                    // the answer
response.toolCalls.map(\.tool)   // ["getWeather", "getWeather", "getWeather"]
```

The one difference from Foundation Models is ``AgentTool/argumentSchema``: this
package ships no macro and takes no dependencies, so the schema `@Generable`
would derive is written out as a ``JSONSchema``. It is what the CLIs are handed
anyway.

A tool that takes nothing declares ``NoArguments`` and needs no schema at all:

```swift
struct CurrentUser: AgentTool {
    let name = "current_user"
    let description = "The signed-in user of this app"

    func call(arguments: NoArguments) async throws -> String {
        await Account.current.displayName
    }
}
```

## How a call actually happens

Not over MCP. Every one of these CLIs can host tools that way, and every route
into it costs something a library should not spend on the user's behalf: a
listening socket — which the App Sandbox blocks without
`com.apple.security.network.server` — or an edit to the user's own CLI
configuration file, which three of the six require.

Instead the exchange is built out of the two things all six already do well: a
structured reply and a resumable session. See ``ToolCallFormat`` for the wire
format and why it is shaped the way it is.

1. The first prompt carries your instructions, the tools, and the reply contract.
2. The agent answers with one JSON object — a call, or the final answer.
3. On a call, ``AgentSession`` runs the tool and **resumes** the session with the
   result.
4. Repeat until the agent answers, or until ``AgentSession/maximumToolRounds``
   is reached.

So a three-tool answer is four CLI invocations, and `response.rounds` reports
that honestly. ``AgentSessionResponse/usage`` is summed across all of them,
because a caller watching spend needs the total rather than the last round's
share.

The CLI must support ``CLICapabilities/sessions`` — resuming is how a result
reaches the agent — and a session without that throws
``AgenticCLIError/unsupportedCapability(_:_:)`` before anything is spent.
Schema enforcement is the part that degrades: a CLI with
``CLICapabilities/nativeOutputSchema`` is handed ``ToolCallFormat/schema`` and
the provider guarantees the shape; `copilot` and `vibe` are asked in the prompt
and parsed leniently.

## When a tool fails

A throwing tool is not a failed run. The error's message goes back to the agent
as a failed result, so it can retry with different arguments or explain the
problem to the person. Naming a tool that does not exist is handled the same
way, with the available names listed in the reply. Both appear in
``AgentSessionResponse/toolCalls`` with ``ToolCall/isError`` set, so the host app
can still see what went wrong.

Two things do fail the run, because no further round would help:

- ``AgenticCLIError/toolCallProtocolViolation(reason:text:)`` — the agent
  produced something unusable twice. It gets exactly one correction; a model that
  cannot produce the format on the second attempt will not produce it on the
  tenth, and every attempt is billed.
- ``AgenticCLIError/toolCallLimitReached(_:rounds:calls:)`` — the agent kept
  calling tools without answering. Raise ``AgentSession/maximumToolRounds`` or
  narrow the task.

## Continuing the conversation

``AgentSession`` keeps the CLI-side session, so a follow-up costs no re-priming:

```swift
_ = try await session.respond(to: "Is it hotter in Boston or Wichita?")
let followUp = try await session.respond(to: "And how does Pittsburgh compare?")
```

For the one-shot case there is ``AgenticCLIKit/AgenticCLIKit/run(_:tools:using:configuration:instructions:maximumToolRounds:)``.

## Known limits

- **`vibe` will not follow the format under ``PermissionPolicy/planOnly`` or
  ``PermissionPolicy/readOnly``.** Both map onto its `plan` agent profile, which
  writes a plan and asks to be taken out of plan mode instead of answering. Use
  ``PermissionPolicy/acceptingEdits`` or
  ``PermissionPolicy/allowingTools(allowed:denied:)`` for a session with tools.
- **Tool calls are sequential.** One call per reply, by design: the format stays
  small enough for every provider to enforce, and results come back in an order
  the agent can reason about.
- **``AgentSession/respond(to:)`` is buffered.** There is no streaming variant,
  because a turn is several runs and the interesting events — which tool, with
  what, returning what — are already reported in
  ``AgentSessionResponse/toolCalls``.
