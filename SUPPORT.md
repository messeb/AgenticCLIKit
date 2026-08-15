# Support

## Documentation

- [README](README.md) — installation, capabilities, and worked examples
- [API documentation](https://messeb.github.io/AgenticCLIKit/documentation/agenticclikit) — generated from DocC
- [CHANGELOG](CHANGELOG.md) — what changed and when

## Getting help

1. Check the documentation above.
2. Run `swift run agentickit health` — most problems are a missing CLI, an outdated CLI, or a signed-out one, and the health report names which.
3. Search [existing issues](https://github.com/messeb/AgenticCLIKit/issues).
4. Ask in [Discussions](https://github.com/messeb/AgenticCLIKit/discussions).
5. For a confirmed bug, open an issue with the bug report template.

## What to include in a bug report

Paste the health report — it names the CLI versions and auth state, and contains no prompts or tokens:

```swift
let report = await AgenticCLIKit().healthReport()
print(report.formattedSummary())
```

If the problem is a parsing failure, `AgentResponse.rawOutput` holds the exact bytes the CLI produced. Redact anything sensitive before posting.

## Known constraints

- **App Sandbox is not supported.** Mac App Store distribution cannot spawn user-installed binaries. See the README.
- **CLI churn.** These CLIs ship breaking changes often. If an adapter suddenly misbehaves, check whether the CLI updated, and include its version.
