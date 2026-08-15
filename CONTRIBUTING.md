# Contributing to AgenticCLIKit

Thanks for your interest in contributing.

## Development setup

```bash
git clone https://github.com/messeb/AgenticCLIKit.git
cd AgenticCLIKit
swift build
swift test
```

Requirements: macOS 13+, Swift 6.0+ (Xcode 26 or a matching toolchain). No CLIs need to be installed for the unit tests — adapters run against recorded transcripts.

## Running the tests

| Command | Scope | Cost |
|---|---|---|
| `swift test` | Unit tests against recorded transcripts | free, no CLIs needed |
| `AGENTICCLIKIT_INTEGRATION=1 swift test` | Adds real discovery and auth probes | free, needs the CLIs installed |
| `AGENTICCLIKIT_LIVE=1 swift test` | Adds real agent turns | **spends your own tokens** |

Open a PR with `swift test` passing. Run the live suite yourself before changing an adapter's flags — that is the only thing that proves a mapping still works.

## The rule that matters most

**Verify adapter behaviour against the real CLI; do not write fixtures by hand.**

Every fixture under `Tests/AgenticCLIKitTests/Fixtures/` is real output captured from a real CLI. A hand-written fixture tests the author's belief about the format, which is exactly the belief that goes stale. When a CLI changes:

1. Re-record the fixture by running the CLI and saving its raw output.
2. **Redact machine-specific content** before committing: absolute home paths, session
   directories, installed plugin or MCP inventories, and any local hook output. Redacting
   is fine; inventing values is not — keep the structure and the fields the parser reads.
3. Note the CLI version in `Fixtures.swift` and in the adapter's doc comment.
4. Update the flag mapping and `minimumSupportedVersion` if needed.

## Adding an adapter

Conform to `ProcessBackedCLI` and you inherit discovery, environment construction, attachment resolution, streaming, timeouts, and cancellation. Supply what is CLI-specific:

- the flags (`makeArguments`)
- the version probe and the **non-interactive** auth probe
- an `AgentOutputTranslating` that maps stdout to `AgentEvent`s

Declare capabilities honestly. If a CLI cannot express something faithfully, throw a typed error rather than substituting something broader — see `PermissionPolicy.allowingTools` on Codex for the pattern.

## Design principles

These are not style preferences; breaking them has caused real bugs:

- **No silent widening.** An adapter that cannot honour a permission policy refuses it.
- **stdin is always closed.** Otherwise CLIs block forever waiting for input.
- **Cancellation kills the process tree**, not just the direct child.
- **Prompts are never logged** by default.
- **`run` is `stream(...).collected()`.** Do not add a second parsing path.

## Pull requests

1. Ensure `swift test` passes and the build is warning-free.
2. Update `CHANGELOG.md` under `[Unreleased]`.
3. Open a PR against `main` with a descriptive title.
4. Address review feedback.

## Commit messages

Use [Conventional Commits](https://www.conventionalcommits.org): `feat:`, `fix:`, `docs:`, `test:`, `refactor:`, `chore:`.

## Code style

Follow the surrounding code: full words over abbreviations, Swift API Design Guidelines naming, doc comments that explain *why* rather than restating the signature. Four-space indentation, 120-column soft limit (see `.editorconfig`).
