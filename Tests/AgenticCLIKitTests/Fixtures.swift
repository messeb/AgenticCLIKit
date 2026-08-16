import Foundation
import Testing

/// Access to the recorded CLI transcripts committed under `Fixtures/`.
///
/// Every fixture is real output captured from the CLI version named in
/// `CompatibilityMatrixTests`, not hand-written. Hand-written fixtures test the
/// parser against the author's belief about the format, which is exactly the
/// belief that goes stale.
enum Fixture {
    static let directory: URL = {
        guard let resourceURL = Bundle.module.resourceURL else {
            fatalError("Test bundle has no resources")
        }
        return resourceURL.appendingPathComponent("Fixtures", isDirectory: true)
    }()

    static func url(_ name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: url(name))
    }

    static func text(_ name: String) throws -> String {
        try String(contentsOf: url(name), encoding: .utf8)
    }

    // Recorded from `claude` 2.1.224
    static let claudeResult = "claude-result.json"
    static let claudeStream = "claude-stream.jsonl"
    static let claudeSchema = "claude-schema.json"
    // Recorded from `codex-cli` 0.147.0
    static let codexStream = "codex-stream.jsonl"
    static let codexResume = "codex-resume.jsonl"
    static let codexSchema = "codex-schema.jsonl"
    // Recorded from GitHub Copilot CLI 1.0.80
    static let copilotStream = "copilot-stream.jsonl"
    // Recorded from `agy` 1.0.16
    static let antigravityResult = "antigravity-result.json"
    static let antigravityStream = "antigravity-stream.jsonl"
    static let antigravityPrint = "antigravity-print.txt"
    static let antigravitySchema = "antigravity-schema.json"
    // Recorded from `vibe` 2.24.1. Absolute paths and the recording machine's
    // user name are replaced; nothing else is altered. `vibe-meta.json` keeps
    // every field this package reads, verbatim — the CLI's own system prompt and
    // tool schemas were dropped from it because they are Mistral's to ship, not
    // this package's.
    static let vibeStream = "vibe-stream.jsonl"
    static let vibeResume = "vibe-resume.jsonl"
    static let vibeTurnLimit = "vibe-turn-limit.jsonl"
    static let vibeMeta = "vibe-meta.json"
}
