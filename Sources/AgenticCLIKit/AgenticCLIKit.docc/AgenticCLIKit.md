# ``AgenticCLIKit``

Drive locally installed AI agent CLIs — Claude Code, Codex, GitHub Copilot, Antigravity, Mistral Vibe, and xAI Grok Build — from a macOS app.

## Overview

The CLIs bring their own authentication, billing, sandboxing, and session storage. This package supplies the typed Swift layer over them: discovery, readiness, one-shot and streaming runs, structured results, attachments, session recovery, and typed errors.

```swift
let kit = AgenticCLIKit()

let response = try await kit.run(
    "Summarise the uncommitted changes",
    using: .claudeCode,
    configuration: .readOnly(in: repositoryURL)
)
```

> Important: A sandboxed app cannot use this package. Spawning arbitrary user-installed binaries is impossible under App Sandbox, so Mac App Store distribution is out of scope. See <doc:Sandboxing>.

## Topics

### Getting started

- <doc:GettingStarted>
- ``AgenticCLIKit/AgenticCLIKit``
- ``HealthReport``

### Running an agent

- ``RunConfiguration``
- ``AgentResponse``
- ``AgentEvent``
- ``AgentEventStream``

### Choosing a model

- <doc:Models>
- ``AgentModel``
- ``KnownModel``

### Deciding what an agent may do

- <doc:Permissions>
- ``PermissionPolicy``
- ``EnvironmentPolicy``

### Typed results

- <doc:TypedResults>
- ``StructuredOutput``
- ``JSONSchema``
- ``StructuredResponse``

### Giving an agent files

- <doc:Attachments>
- ``PromptAttachment``
- ``ResolvedAttachment``

### Continuing a conversation

- <doc:Sessions>
- ``SessionReference``
- ``SessionStore``
- ``FileSessionStore``
- ``InMemorySessionStore``

### The adapters

- ``AgenticCLI``
- ``CLIIdentifier``
- ``CLICapabilities``
- ``Installation``
- ``AuthenticationStatus``
- ``ClaudeCode``
- ``Codex``
- ``Copilot``
- ``Antigravity``
- ``Vibe``

### Extending the kit

- <doc:WritingAnAdapter>
- ``ProcessBackedCLI``
- ``AgentOutputTranslating``
- ``ProcessRunner``
- ``ExecutableLocating``

### Handling failure

- ``AgenticCLIError``
- ``Readiness``
