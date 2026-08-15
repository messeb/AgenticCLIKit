# Changelog

All notable changes to this project are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

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
- `agentickit` demo command-line tool.

[Unreleased]: https://github.com/messeb/AgenticCLIKit/commits/main
