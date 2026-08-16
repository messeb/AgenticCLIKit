# Typed Results

Ask for a Swift record and get one, enforced by the provider.

## Overview

All three prompting CLIs accept a JSON Schema and constrain the model's final message to match it. Decoding on the Swift side is therefore checking a contract that was already enforced, not hoping the model remembered to reply in JSON.

```swift
struct CommitMessage: StructuredOutput {
    let commitSubject: String
    let commitDescription: String

    static let outputSchema = JSONSchema.object([
        "commitSubject": .string("Imperative mood, at most 50 characters"),
        "commitDescription": .string("Body explaining why the change was made"),
    ])
}

let response = try await kit.run(
    "Summarise the uncommitted changes as a commit message",
    returning: CommitMessage.self,
    using: .claudeCode,
    configuration: .readOnly(in: repositoryURL)
)

response.value.commitSubject
response.usage?.costUSD
response.session
```

## Why the response is not generic

``AgentResponse`` is the payload of ``AgentEvent/finished(_:)``. Making it generic would push a type parameter through ``AgentEvent``, ``AgentEventStream``, and every adapter — for a value that only exists on the buffered path. ``StructuredResponse`` wraps it instead and forwards member lookups, so `response.session`, `response.usage`, and `response.text` all keep working alongside `response.value`.

## Writing a schema

``JSONSchema`` covers the subset the CLIs enforce. Every property is required and `additionalProperties` is `false` by default, because a schema that permits missing keys defeats the point — the Swift type would fail to decode anyway.

```swift
static let outputSchema = JSONSchema.object([
    "severity": .string("How serious", oneOf: ["low", "medium", "high"]),
    "findings": .array(of: .object([
        "file": .string(),
        "line": .integer(),
    ])),
    "summary": .optional(.string("Only when there is something to add")),
])
```

`.optional(_:)` keeps a property out of the required list. `.raw(json:)` takes a hand-written schema for anything the builder does not model.

## Per-CLI behaviour

Three details, all found by running the CLIs rather than reading their help:

- **`claude`** takes the schema inline and reports the validated object in a dedicated `structured_output` field as well as in `result`.
- **`codex`** takes the schema as a *file path*, so schema runs get a scratch directory that is removed when the run ends.
- **`agy`** fills `structured_output` only in its buffered `json` mode, and returns an **empty response** if a schema is combined with plan mode. The adapter switches to `json` for schema runs and refuses ``PermissionPolicy/planOnly`` with an explanation — use ``PermissionPolicy/readOnly``. Schema runs on that CLI therefore produce no streaming deltas.

Decoding prefers the CLI's structured field over the message text. That order matters: `agy` returns prose *and* JSON in its text, so text-first parsing would hand back the prose.

## When it does not fit

``AgenticCLIError/structuredOutputFailed(reason:text:)`` carries the text that failed, so it can be logged or retried.

A CLI that cannot enforce a schema — Copilot, which streams JSON but has no flag that constrains the reply — throws ``AgenticCLIError/unsupportedCapability(_:_:)`` rather than degrading to "please reply with JSON and hope".

## Without a Swift type

Set ``RunConfiguration/outputSchema`` directly to constrain the output without decoding it, then reach for ``AgentResponse/structuredOutput`` or ``AgentResponse/decode(as:using:)``.
