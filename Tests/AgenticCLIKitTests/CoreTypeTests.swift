import Foundation
import Testing

@testable import AgenticCLIKit

@Suite("SemanticVersion")
struct SemanticVersionTests {
    @Test("Parses strict versions")
    func parsesStrictVersions() throws {
        #expect(SemanticVersion("1.2.3") == SemanticVersion(1, 2, 3))
        #expect(SemanticVersion("2.1") == SemanticVersion(2, 1, 0))
        #expect(SemanticVersion("1.0.0-beta.2")?.prereleaseIdentifiers == ["beta", "2"])
        #expect(SemanticVersion("1.0.0+build7")?.buildMetadata == "build7")
        #expect(SemanticVersion("not-a-version") == nil)
        #expect(SemanticVersion("1") == nil)
    }

    /// The exact strings the four CLIs print today.
    @Test(
        "Extracts versions from real CLI output",
        arguments: [
            ("2.1.224 (Claude Code)", SemanticVersion(2, 1, 224)),
            ("codex-cli 0.147.0", SemanticVersion(0, 147, 0)),
            ("gh version 2.97.0 (2026-07-31)\nhttps://github.com/cli/cli/releases", SemanticVersion(2, 97, 0)),
            ("1.0.16", SemanticVersion(1, 0, 16)),
        ]
    )
    func extractsFromCLIOutput(input: String, expected: SemanticVersion) {
        #expect(SemanticVersion(parsingFirstMatchIn: input) == expected)
    }

    @Test("Orders by precedence, prereleases first")
    func ordersByPrecedence() {
        let release = SemanticVersion("1.0.0")!
        let beta = SemanticVersion("1.0.0-beta")!
        let alpha = SemanticVersion("1.0.0-alpha")!
        let alphaOne = SemanticVersion("1.0.0-alpha.1")!
        let alphaTwo = SemanticVersion("1.0.0-alpha.2")!
        let numericPrerelease = SemanticVersion("1.0.0-1")!
        let buildA = SemanticVersion("1.0.0+a")!
        let buildB = SemanticVersion("1.0.0+b")!

        #expect(SemanticVersion(1, 0, 0) < SemanticVersion(1, 0, 1))
        #expect(SemanticVersion(1, 9, 0) < SemanticVersion(2, 0, 0))
        #expect(beta < release)
        #expect(alpha < beta)
        #expect(alphaOne < alphaTwo)
        // Numeric prerelease identifiers sort before alphanumeric ones.
        #expect(numericPrerelease < alpha)
        // Build metadata is ignored for ordering.
        #expect(!(buildA < buildB))
        #expect(!(buildB < buildA))
    }

    @Test("Round-trips through its description")
    func roundTrips() {
        for text in ["1.2.3", "0.147.0", "1.0.0-beta.1", "2.0.0+sha.abc"] {
            #expect(SemanticVersion(text)?.description == text)
        }
    }
}

@Suite("LineAccumulator")
struct LineAccumulatorTests {
    @Test("Reassembles lines split across chunk boundaries")
    func reassemblesAcrossChunks() {
        var accumulator = LineAccumulator()
        #expect(accumulator.append(Data(#"{"a":"# .utf8)).isEmpty)
        #expect(accumulator.append(Data("1}\n".utf8)) == [#"{"a":1}"#])
    }

    @Test("Splits multiple lines in one chunk")
    func splitsMultipleLines() {
        var accumulator = LineAccumulator()
        #expect(accumulator.append(Data("one\ntwo\nthree\n".utf8)) == ["one", "two", "three"])
    }

    @Test("Handles CRLF and blank lines")
    func handlesCRLF() {
        var accumulator = LineAccumulator()
        #expect(accumulator.append(Data("one\r\n\n  \ntwo\r\n".utf8)) == ["one", "two"])
    }

    @Test("Flushes a trailing line with no newline")
    func flushesTrailingLine() {
        var accumulator = LineAccumulator()
        #expect(accumulator.append(Data("done".utf8)).isEmpty)
        #expect(accumulator.flush() == "done")
        #expect(accumulator.flush() == nil)
    }

    /// Byte-at-a-time is the pathological case a real pipe can produce under
    /// load, and the one most likely to break a naive splitter.
    @Test("Survives one-byte-at-a-time delivery")
    func survivesByteAtATime() {
        var accumulator = LineAccumulator()
        var lines: [String] = []
        for byte in Data("alpha\nbeta\ngamma\n".utf8) {
            lines += accumulator.append(Data([byte]))
        }
        #expect(lines == ["alpha", "beta", "gamma"])
    }
}

@Suite("EnvironmentPolicy")
struct EnvironmentPolicyTests {
    @Test("Passes through only allowlisted variables")
    func filtersHostEnvironment() {
        let host = [
            "PATH": "/usr/bin",
            "HOME": "/Users/test",
            "AWS_SECRET_ACCESS_KEY": "super-secret",
            "STRIPE_KEY": "sk_live_nope",
        ]
        let resolved = EnvironmentPolicy.base.resolved(againstHostEnvironment: host)

        #expect(resolved["PATH"] == "/usr/bin")
        #expect(resolved["HOME"] == "/Users/test")
        #expect(resolved["AWS_SECRET_ACCESS_KEY"] == nil)
        #expect(resolved["STRIPE_KEY"] == nil)
    }

    @Test("Forces non-interactive terminal settings")
    func forcesNonInteractiveDefaults() {
        let resolved = EnvironmentPolicy.base.resolved(againstHostEnvironment: ["TERM": "xterm-256color"])
        #expect(resolved["TERM"] == "dumb")
        #expect(resolved["NO_COLOR"] == "1")
    }

    @Test("Adapters opt into their own credential variables")
    func inheritsCredentialVariables() {
        let host = ["ANTHROPIC_API_KEY": "sk-ant-test", "OPENAI_API_KEY": "sk-openai"]
        let policy = EnvironmentPolicy.base.inheriting("ANTHROPIC_API_KEY")
        let resolved = policy.resolved(againstHostEnvironment: host)

        #expect(resolved["ANTHROPIC_API_KEY"] == "sk-ant-test")
        // Codex's key must not leak into a Claude run.
        #expect(resolved["OPENAI_API_KEY"] == nil)
    }

    @Test("Caller overrides win over policy defaults")
    func overridesWin() {
        let resolved = EnvironmentPolicy.base.resolved(
            againstHostEnvironment: [:],
            additionalOverrides: ["TERM": "xterm"]
        )
        #expect(resolved["TERM"] == "xterm")
    }

    @Test("Reports which credential variables are actually present")
    func reportsPresentKeys() {
        let policy = EnvironmentPolicy.base.inheriting(["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN"])
        let present = policy.presentKeys(
            among: ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN"],
            in: ["ANTHROPIC_API_KEY": "sk-ant", "ANTHROPIC_AUTH_TOKEN": ""]
        )
        // An empty value is not a credential.
        #expect(present == ["ANTHROPIC_API_KEY"])
    }
}

@Suite("Capabilities and identifiers")
struct CapabilityTests {
    @Test("Capabilities describe themselves for diagnostics")
    func describesItself() {
        let capabilities: CLICapabilities = [.sessions, .streaming]
        #expect(capabilities.description.contains("sessions"))
        #expect(capabilities.description.contains("streaming"))
        #expect(CLICapabilities().description == "[]")
    }

    @Test("Capability bits are distinct")
    func bitsAreDistinct() {
        let all: [CLICapabilities] = [
            .prompting, .sessions, .streaming, .structuredOutput, .modelSelection,
            .turnLimits, .usageReporting, .toolAllowlist, .resumeAcrossDirectories,
            .ephemeralRuns, .additionalDirectories, .systemPromptCustomization, .experimental,
        ]
        #expect(Set(all.map(\.rawValue)).count == all.count)
    }

    @Test("Identifiers are extensible without touching the core")
    func identifiersAreExtensible() {
        let custom: CLIIdentifier = "aider"
        #expect(custom.rawValue == "aider")
        #expect(custom != .claudeCode)
    }
}

@Suite("Errors")
struct ErrorTests {
    @Test("Every error names its CLI where one applies")
    func attributesErrors() {
        #expect(AgenticCLIError.notInstalled(.codex, installHint: "x").cli == .codex)
        #expect(AgenticCLIError.timedOut(.claudeCode, after: .seconds(1)).cli == .claudeCode)

        let session = SessionReference(
            cli: .antigravity,
            sessionID: "abc",
            workingDirectory: URL(fileURLWithPath: "/tmp")
        )
        #expect(AgenticCLIError.sessionNotFound(session).cli == .antigravity)
        #expect(AgenticCLIError.malformedOutput(reason: "x", raw: nil).cli == nil)
    }

    @Test("Blocked states carry an actionable next step")
    func carriesRecovery() {
        let error = AgenticCLIError.notAuthenticated(.github, loginCommand: "gh auth login")
        #expect(error.recoverySuggestion?.contains("gh auth login") == true)
        #expect(error.localizedDescription.contains("gh auth login"))
        #expect(!error.isTransient)
        #expect(AgenticCLIError.timedOut(.codex, after: .seconds(5)).isTransient)
    }
}
