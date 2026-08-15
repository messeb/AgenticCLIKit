# Getting Started

Check what is available, then run something.

## Overview

Add the package:

```swift
.package(url: "https://github.com/messeb/AgenticCLIKit.git", from: "1.0.0")
```

The package needs macOS 13+ and Swift 6, and has no third-party dependencies.

## Find out what the user has

Nothing works if the CLI is missing, outdated, or signed out — so ask first. Probes are non-interactive by contract: they never open a browser and never prompt.

```swift
let kit = AgenticCLIKit()
let report = await kit.healthReport()

print(report.formattedSummary())
// ✓ Claude Code 2.1.224 — you@example.com via subscription
// ✓ Codex 0.147.0 — authenticated via subscription
// ✗ Antigravity — not installed
//     → Install Antigravity from https://antigravity.google, then run `agy install`

for entry in report.entries where !entry.isReady {
    show(entry.displayName, blocker: entry.blocker, action: entry.suggestedAction)
}
```

Repeat calls in a running app should pass ``AgenticCLIKit/AgenticCLIKit/healthReport(maximumAge:)`` so a status bar does not re-probe the network every few seconds.

## Run a prompt

``RunConfiguration`` requires a working directory and a permission policy. There is no default policy — see <doc:Permissions>.

```swift
let response = try await kit.run(
    "Which files changed most recently, and why might that be?",
    using: .claudeCode,
    configuration: .readOnly(in: repositoryURL)
)

print(response.text)
print(response.usage?.costUSD ?? 0)
```

## Stream it instead

```swift
for try await event in kit.stream(prompt, using: .claudeCode, configuration: configuration) {
    switch event {
    case .assistantTextDelta(let text): transcript += text
    case .toolUseRequested(let tool):   status = "Running \(tool.name)…"
    case .finished(let response):       complete(response)
    default: break
    }
}
```

To stop a run, cancel the `Task`. Breaking out of the loop only terminates the CLI once the stream value is released.

## Handle the predictable failures

```swift
do {
    let response = try await kit.run(prompt, using: .codex, configuration: configuration)
} catch let error as AgenticCLIError {
    switch error {
    case .notInstalled(_, let hint):        showInstallSheet(hint)
    case .notAuthenticated(_, let command): showSignInButton(runs: command)
    case .timedOut:                         offerRetry()
    default:                                report(error)
    }
}
```

## Next

- <doc:Permissions> — what the agent may do
- <doc:TypedResults> — get a Swift record instead of prose
- <doc:Attachments> — hand the agent files or URLs
- <doc:Sessions> — continue a conversation after a relaunch
