# Changelog

All notable changes to this project are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Tool calling. `AgentTool` (typed) and `AgentFunction` (raw JSON) describe a
  host function; `AgentSession` runs the exchange — the agent asks for a tool,
  the session runs it and resumes the conversation with the result — until an
  answer arrives or `maximumToolRounds` is reached. No MCP server, socket, or
  edit to the user's CLI configuration. Verified live, including a follow-up
  turn, on all six CLIs, all read-only. `agentickit tools <cli>` runs the worked example.

### Changed

- Verified against Claude Code 2.1.296, Codex 0.162.1, GitHub Copilot CLI
  1.0.95, Antigravity 1.3.2, Mistral Vibe 2.26.1, and Grok Build 1.0.50.

### Fixed

- Mistral Vibe 2.26 runs the Unified Harness by default. A resumed run no
  longer replays the transcript or prints a checkpoint, which left the adapter
  suppressing the whole answer; the new turn's prompt now ends the replay too.
- Mistral Vibe 2.26 moved its session log to `logs/session/unified/<id>/` and
  stopped recording per-turn tokens and prices. Usage is now read from the
  store's public snapshot as the change in session totals across the run, and
  priced from `config.toml` or, for the remotely routed default model, the
  cached rollout payload. Legacy logs are still read for 2.24–2.25.
- Antigravity 1.3 ends a print-mode turn with an empty reply — still
  `SUCCESS` — when it denies a tool it cannot prompt for. The denial is now
  reported as `.permissionDenied` events and an error response with stop
  reason `PERMISSION_DENIED`, and decoding structured output from such a run
  says why there is nothing to decode.
- Antigravity 1.3 runs `--mode plan` through its `/plan` workflow, which
  reaches for shell commands and so ended most plan and read-only runs empty.
  From 1.3 those runs pass `--disable-slash-commands`; the mode and sandbox
  still apply.
- Antigravity 1.3 reports structured output under `stream-json` and, with the
  `/plan` workflow off, honours a schema in plan mode. From 1.3 schema runs
  stream and `.planOnly` is no longer refused for them.
- A resumed turn reported the whole conversation's tokens on Codex and
  Antigravity: both put the thread's running total where the turn's usage
  belongs. Codex usage is now the change in the thread total recorded in its
  rollout log; Antigravity usage is the sum of the run's own model steps. A
  tool-calling session sums its rounds, so its overcount grew quadratically
  with their number.
- The `agentickit tools` demo derived temperatures from `hashValue`, which
  Swift seeds per process, so the same city changed temperature between runs.

## [1.3.0] - 2026-08-18

## [1.2.1] - 2026-08-16

### Fixed

- Re-encoding a `null` or scalar tool payload no longer aborts the host process.
  `JSONSerialization.data(withJSONObject:)` raises an Objective-C exception that
  `try?` cannot catch, and `vibe` prints `"input": null` for any tool call
  carrying no arguments. The same unguarded pattern is corrected in the Claude
  Code, Copilot, and Antigravity translators.

## [1.2.0] - 2026-08-16

### Added

- Adapter for Mistral Vibe (`vibe`), verified against 2.24.1: streaming NDJSON,
  sessions with cross-directory resume, a per-tool allowlist, and file
  attachments. Marked experimental — the CLI ships roughly weekly.
- `RunConfiguration.maximumTurns` is honoured for the first time. `vibe` counts
  turns across the whole session, so `Vibe.Adapter` offsets the limit by the
  session's recorded step count and the value keeps its meaning on resume.
- Token and USD-cost reporting for `vibe`, read from its session log
  (`$VIBE_HOME/logs/session/…/meta.json`) after the process exits, since none of
  it reaches stdout. Missing logs cost the usage, never the run.
- `Vibe.Model` and discovery from `~/.vibe/config.toml`. A model alias `vibe`
  does not know is refused with `.unsupportedModel`, because `vibe` would
  otherwise ignore it and bill the run on its default model.

## [1.1.0] - 2026-08-16

## [1.0.1] - 2026-08-15

## [1.0.0] - 2026-08-15

### Added

- `AgenticCLI` protocol with adapters for Claude Code (`claude`), Codex (`codex`), GitHub (`gh`), and Antigravity (`agy`).
- Discovery via login-shell `PATH` resolution, so CLIs stay visible to apps launched from Finder.
- Non-interactive authentication probes for every adapter, including `agy models` for Antigravity, which ships no auth-status command.
- One-shot and streaming runs, with `AgentEvent` streams and a `raw(Data)` escape hatch for unmapped events.
- Session capture and resume, with `SessionStore`, an in-memory store, and a file-backed store.
- Structured output: `StructuredOutput`, `JSONSchema`, and `StructuredResponse<Value>`, backed by each CLI's native schema enforcement.
- Attachments: local files, in-memory data, and remote URLs downloaded before the run, with per-run scratch directories.
- `PermissionPolicy` as a required, explicit choice on every run.
- `HealthReport` for status screens and bug reports, with concurrent probes and optional caching.
- `AgenticCLIKitTesting` with `RecordedProcessRunner` for testing against recorded CLI transcripts.
- Model discovery: `AgentModel`, `KnownModel`, and `availableModels()`, backed by
  Antigravity's live catalogue and hand-maintained lists for the two CLIs that
  cannot enumerate their models.
- `agentickit` demo command-line tool.

[Unreleased]: https://github.com/messeb/AgenticCLIKit/commits/main
[1.0.0]: https://github.com/messeb/AgenticCLIKit/releases/tag/1.0.0
[1.0.1]: https://github.com/messeb/AgenticCLIKit/releases/tag/1.0.1
[1.1.0]: https://github.com/messeb/AgenticCLIKit/releases/tag/1.1.0
[1.2.0]: https://github.com/messeb/AgenticCLIKit/releases/tag/1.2.0
[1.2.1]: https://github.com/messeb/AgenticCLIKit/releases/tag/1.2.1
[1.3.0]: https://github.com/messeb/AgenticCLIKit/releases/tag/1.3.0
