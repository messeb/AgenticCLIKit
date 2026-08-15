# Writing an Adapter

Support another CLI without touching the core.

## Overview

Adding a CLI means conforming to ``ProcessBackedCLI``. Discovery, environment construction, attachment resolution, streaming, timeouts, and cancellation are inherited. What is left is genuinely CLI-specific.

```swift
public enum Aider {}

extension Aider {
    public struct Adapter: ProcessBackedCLI {
        public static let identifier = CLIIdentifier("aider")

        public let runner: any ProcessRunner
        public let locator: any ExecutableLocating

        public var displayName: String { "Aider" }
        public var executableName: String { "aider" }
        public var installHint: String { "pipx install aider-chat" }
        public var loginCommand: String { "aider --login" }
        public var minimumSupportedVersion: SemanticVersion { SemanticVersion(0, 70, 0) }
        public var capabilities: CLICapabilities { [.prompting, .streaming] }
        public var environmentPolicy: EnvironmentPolicy { .base.inheriting("AIDER_API_KEY") }
    }
}
```

``CLIIdentifier`` is open-ended, so a new identifier lives alongside the adapter rather than in the core.

## The four things to supply

1. **Flags.** Build the argument vector from ``RunConfiguration``.
2. **A version probe.** Usually the inherited `--version` handling is enough.
3. **An authentication probe.** It must be non-interactive, must never open a browser, and must run under ``ProcessBackedCLI/probeTimeout``. Some CLIs block waiting for input when signed out; that is why the timeout is a correctness requirement rather than a nicety.
4. **A translator.** Conform to ``AgentOutputTranslating`` to map stdout lines to ``AgentEvent`` values and build the final ``AgentResponse``.

## Declare capabilities honestly

``CLICapabilities`` is what callers branch on. Claiming something the CLI cannot do moves the failure from a clear typed error to a confusing runtime one.

When the CLI cannot express a request faithfully, throw:

```swift
case .allowingTools:
    throw AgenticCLIError.unsupportedPermissionPolicy(
        Self.identifier,
        policy,
        reason: "aider grants tools globally, not by name"
    )
```

## Map failures to meaning

Exit codes are rarely informative on their own. Translate them, keeping prose matches broad and additive so a reworded message degrades to ``AgenticCLIError/processFailed(_:exitCode:standardError:)`` rather than being misclassified.

## Test against recorded output

Adapters talk to the world only through ``ProcessRunner``, so tests replay real transcripts:

```swift
let runner = RecordedProcessRunner(matching: [
    "--version": .output("aider 0.71.0"),
    "--message": try .fixture(recordedTranscriptURL, chunkSize: 64),
])
let adapter = Aider.Adapter(runner: runner, locator: FakeExecutableLocator())
```

Record fixtures from the real CLI; never write them by hand. `chunkSize` deliberately splits output mid-object, because pipe reads do, and that is where naive parsers break.

## Register it

```swift
let kit = AgenticCLIKit(agents: AgenticCLIKit.defaultAgents() + [Aider.Adapter()])
```
