# Changelog

All notable changes to this project are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

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
