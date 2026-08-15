# Sessions

Continue a conversation after the app restarts.

## Overview

``SessionReference`` holds metadata only: an identifier, a directory, timestamps. The transcript stays in the CLI's own storage, which is exactly why resume survives process exit and reboots — and why the reference is safe to persist anywhere.

```swift
let kit = AgenticCLIKit(sessionStore: try FileSessionStore.applicationSupport())

// Today
let response = try await kit.run(prompt, using: .claudeCode, configuration: configuration)

// Tomorrow, after a relaunch
let followUp = try await kit.continueOrStart(
    "Now write the tests",
    using: .claudeCode,
    configuration: configuration
)
```

``AgenticCLIKit/AgenticCLIKit/continueOrStart(_:using:configuration:)`` resumes when the CLI still knows the session and starts a fresh one when it has forgotten it, dropping the stale reference.

## Streaming records the session immediately

The session is stored when ``AgentEvent/sessionStarted(_:)`` arrives, not at the end of the run. A run that is cancelled halfway still leaves a resumable conversation, and losing its identifier would strand the user's work.

## Directory scope differs per CLI

`claude` and `codex` resume by identifier from anywhere. Antigravity does not document cross-directory resume, so its adapter validates the working directory and throws ``AgenticCLIError/workingDirectoryMismatch(_:attempted:)`` rather than letting the CLI fail confusingly later.

Branch on the capability, not on the CLI name:

```swift
let scope = agent.capabilities.contains(.resumeAcrossDirectories) ? nil : workingDirectory
let session = try await store.mostRecentSession(for: agent.identifier, in: scope)
```

## Bring your own storage

``SessionStore`` is four methods. Implement it over Core Data, SwiftData, or CloudKit if the app already has a database. ``InMemorySessionStore`` is the default so nothing is written to disk unless asked; ``FileSessionStore`` writes an atomic JSON index and prunes references older than 30 days, because a store full of unresumable identifiers is worse than an empty one.
