# Copilot Instructions

## Project overview

AgenticCLIKit is a Swift package that lets a macOS app drive locally installed AI agent CLIs — Claude Code (`claude`), Codex (`codex`), Antigravity (`agy`) — and the GitHub CLI (`gh`). It handles discovery, authentication probes, permissions, runs, streaming, structured output, attachments, and session recovery.

## Tech stack

- Swift 6, strict concurrency, `Sendable`-clean public API
- SwiftPM; macOS 13+
- **Zero third-party dependencies** — Foundation and `os` only. Do not add a dependency without discussion; it is a stated property of the package.
- Swift Testing (`import Testing`), not XCTest

## Architecture

- `Core/` — protocols and value types (`AgenticCLI`, `RunConfiguration`, `PermissionPolicy`, `AgentEvent`, errors)
- `Process/` — `SubprocessRunner`, process-tree termination, login-shell `PATH` resolution, line reassembly, attachment resolution
- `Adapters/<CLI>/` — one namespace enum per CLI, containing `Adapter` and a `Translator`
- `Session/` — `SessionStore` and implementations
- Adapters reach the outside world only through `ProcessRunner`, which is what makes them testable

## Conventions

- Full words over abbreviations; Swift API Design Guidelines naming (`AgenticCLI`, not `AgentCLI`; `SessionReference`, not `SessionRef`)
- Namespaced types (`ClaudeCode.Adapter`) rather than prefixes (`ClaudeCodeAdapter`)
- Doc comments explain *why*, not what the signature already says
- Comments earn their place; do not restate code

## Non-negotiable behaviours

Breaking any of these has caused real bugs:

1. **Never silently widen a permission policy.** Throw a typed error instead.
2. **stdin is always closed** for child processes, or prompt-waiting CLIs hang forever.
3. **Cancellation and timeouts kill the whole process tree**, not just the direct child.
4. **Prompts are never logged** unless `Log.isPromptLoggingEnabled` is set.
5. **`run` is `stream(...).collected()`.** Never add a second parsing path.
6. **Fixtures are recorded from real CLIs**, never hand-written.

## Testing

```bash
swift test                              # unit tests, no CLIs needed
AGENTICCLIKIT_INTEGRATION=1 swift test  # + real discovery and auth probes
AGENTICCLIKIT_LIVE=1 swift test         # + real agent turns; spends tokens
```

## Important context

- The four CLIs ship breaking changes frequently. Every adapter names the version it was verified against; keep that current.
- Adapters declare `CLICapabilities`; callers must branch on capabilities rather than on CLI identity.
- `gh` is intentionally capability-poor. It exists to keep the abstraction honest — do not "fix" it by adding prompting.
