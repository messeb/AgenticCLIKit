import Foundation
import Testing

@testable import AgenticCLIKit

/// Gates for the tests that touch real CLIs.
///
/// Two levels, because the costs differ by orders of magnitude: probes are free
/// and fast, agent turns cost the developer's own tokens.
enum IntegrationGate {
    /// `AGENTICCLIKIT_INTEGRATION=1` — discovery and auth probes only. No
    /// tokens spent, no files touched.
    static var probesEnabled: Bool {
        ProcessInfo.processInfo.environment["AGENTICCLIKIT_INTEGRATION"] == "1"
    }

    /// `AGENTICCLIKIT_LIVE=1` — real agent turns. Spends tokens.
    static var liveRunsEnabled: Bool {
        ProcessInfo.processInfo.environment["AGENTICCLIKIT_LIVE"] == "1"
    }
}

@Suite(
    "Integration: discovery and auth",
    .enabled(if: IntegrationGate.probesEnabled, "Set AGENTICCLIKIT_INTEGRATION=1"),
    .timeLimit(.minutes(2))
)
struct DiscoveryIntegrationTests {
    /// The performance target, split by what it actually costs. The three CLIs
    /// with local credential checks are the fast path a launch screen depends
    /// on; `agy` has no local check and spends ~2s asking its backend, which no
    /// amount of parallelism removes.
    @Test("Locally-probed CLIs are ready well inside the 2s budget")
    func probesLocalCLIsQuickly() async throws {
        let locator = LoginShellExecutableLocator()
        let kit = AgenticCLIKit(agents: [
            ClaudeCode.Adapter(locator: locator),
            Codex.Adapter(locator: locator),
            GitHub.Adapter(locator: locator),
        ])

        let clock = ContinuousClock()
        let started = clock.now
        let report = await kit.healthReport()
        let elapsed = clock.now - started

        print(report.formattedSummary())
        print("three local CLIs probed in \(elapsed.seconds)s")
        #expect(elapsed < .seconds(2))
    }

    @Test("All four CLIs probe concurrently, bounded by the slowest one")
    func probesAllCLIsConcurrently() async throws {
        let kit = AgenticCLIKit()
        let clock = ContinuousClock()
        let started = clock.now
        let report = await kit.healthReport()
        let elapsed = clock.now - started

        print(report.formattedSummary())
        print("all four probed in \(elapsed.seconds)s")
        #expect(report.entries.count == 4)
        // Comfortably below the ~3s a serial pass over the same probes takes.
        #expect(elapsed < .seconds(5))

        // A repeat call inside the cache window must not re-probe at all.
        let cachedStart = clock.now
        _ = await kit.healthReport(maximumAge: .seconds(60))
        #expect((clock.now - cachedStart) < .milliseconds(50))
    }

    @Test("Discovery reports a version for whatever is installed")
    func discoversVersions() async throws {
        for agent in AgenticCLIKit.defaultAgents() {
            let installation = await agent.installation()
            guard installation.isInstalled else {
                print("skipping \(agent.identifier): not installed")
                continue
            }
            #expect(installation.version != nil, "\(agent.identifier) printed no parseable version")
            #expect(installation.meetsMinimumVersion, "\(agent.identifier) is below its minimum version")
        }
    }

    /// A probe that opens a browser or blocks on a prompt would make the app
    /// unusable at launch. Bounding the time is the observable proxy.
    @Test("Auth probes are non-interactive and bounded")
    func authProbesAreBounded() async throws {
        for agent in AgenticCLIKit.defaultAgents() {
            guard await agent.installation().isInstalled else { continue }

            let clock = ContinuousClock()
            let started = clock.now
            let status = await agent.authenticationStatus()
            let elapsed = clock.now - started

            print("\(agent.identifier): \(status) in \(elapsed.seconds)s")
            // `agy` reaches the network for its probe and gets a larger budget.
            let budget: Duration = agent.identifier == .antigravity ? .seconds(20) : .seconds(8)
            #expect(elapsed < budget)

            if case .probeFailed(let reason) = status {
                Issue.record("\(agent.identifier) probe failed: \(reason)")
            }
        }
    }

    @Test("gh runs a real command and returns typed JSON")
    func runsGitHubCommand() async throws {
        let adapter = GitHub.Adapter()
        guard await adapter.installation().isInstalled else { return }

        let configuration = RunConfiguration(
            workingDirectory: FileManager.default.temporaryDirectory,
            permissions: .readOnly
        )
        let response = try await adapter.execute(["--version"], configuration: configuration)
        #expect(response.text.contains("gh version"))
    }
}

@Suite(
    "Integration: live agent runs",
    .enabled(if: IntegrationGate.liveRunsEnabled, "Set AGENTICCLIKIT_LIVE=1 — this spends tokens"),
    .timeLimit(.minutes(10)),
    .serialized
)
struct LiveRunIntegrationTests {
    /// A scratch directory, so no test can touch the developer's own files even
    /// if a permission mapping is wrong.
    private func withScratchDirectory(_ body: (URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentickit-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(directory)
    }

    /// The mapping most likely to hang: `--permission-mode manual` relies on
    /// print mode auto-denying rather than prompting. If that assumption is
    /// ever wrong, this test blocks until the timeout instead of passing.
    @Test("Claude honours read-only without waiting for a permission prompt")
    func claudeReadOnlyDoesNotHang() async throws {
        let adapter = ClaudeCode.Adapter()
        try await adapter.verifyReady()

        try await withScratchDirectory { directory in
            let response = try await adapter.run(
                "Reply with exactly: OK",
                configuration: RunConfiguration(
                    workingDirectory: directory,
                    permissions: .readOnly,
                    timeout: .seconds(120)
                )
            )
            #expect(response.text.contains("OK"))
            #expect(response.session != nil)
        }
    }

    @Test("Claude resumes a session from a different directory")
    func claudeResumesAcrossDirectories() async throws {
        let adapter = ClaudeCode.Adapter()
        try await adapter.verifyReady()

        try await withScratchDirectory { first in
            let opening = try await adapter.run(
                "Remember the word: albatross. Reply with exactly: STORED",
                configuration: .planOnly(in: first, timeout: .seconds(120))
            )
            let session = try #require(opening.session)

            try await withScratchDirectory { second in
                let resumed = try await adapter.resume(
                    session,
                    with: "What word did I ask you to remember? Reply with only that word.",
                    configuration: .planOnly(in: second, timeout: .seconds(120))
                )
                #expect(resumed.text.lowercased().contains("albatross"))
                #expect(resumed.session?.sessionID == session.sessionID)
            }
        }
    }

    @Test("Claude streams text incrementally")
    func claudeStreamsIncrementally() async throws {
        let adapter = ClaudeCode.Adapter()
        try await adapter.verifyReady()

        try await withScratchDirectory { directory in
            var deltas: [String] = []
            var sawSession = false

            for try await event in adapter.stream(
                "Count from 1 to 5, one number per line.",
                configuration: .planOnly(in: directory, timeout: .seconds(120))
            ) {
                switch event {
                case .sessionStarted: sawSession = true
                case let .assistantTextDelta(text): deltas.append(text)
                default: continue
                }
            }

            #expect(sawSession)
            // Streaming, not one lump at the end.
            #expect(deltas.count > 1)
            #expect(deltas.joined().contains("3"))
        }
    }

    @Test("Codex runs and resumes by session ID")
    func codexRunsAndResumes() async throws {
        let adapter = Codex.Adapter()
        try await adapter.verifyReady()

        try await withScratchDirectory { directory in
            let configuration = RunConfiguration(
                workingDirectory: directory,
                permissions: .readOnly,
                timeout: .seconds(180)
            )
            let opening = try await adapter.run("Reply with exactly: OK", configuration: configuration)
            #expect(opening.text.contains("OK"))

            let session = try #require(opening.session)
            let resumed = try await adapter.resume(
                session,
                with: "Reply with exactly: RESUMED",
                configuration: configuration
            )
            #expect(resumed.text.contains("RESUMED"))
            #expect(resumed.session?.sessionID == session.sessionID)
        }
    }

    @Test("Antigravity runs in plan mode and reports a conversation")
    func antigravityRuns() async throws {
        let adapter = Antigravity.Adapter()
        try await adapter.verifyReady()

        try await withScratchDirectory { directory in
            let response = try await adapter.run(
                "Reply with exactly: OK",
                configuration: .planOnly(in: directory, timeout: .seconds(180))
            )
            #expect(response.text.contains("OK"))
            #expect(response.session != nil)
            #expect(response.usage?.inputTokens != nil)
        }
    }

    /// Cancellation has to work against a real agent, not just against `sleep`.
    @Test("Cancelling a live run terminates the CLI promptly")
    func cancellationStopsALiveRun() async throws {
        let adapter = ClaudeCode.Adapter()
        try await adapter.verifyReady()

        try await withScratchDirectory { directory in
            let configuration = RunConfiguration(
                workingDirectory: directory,
                permissions: .planOnly,
                timeout: .seconds(300)
            )
            let task = Task {
                try await adapter.run("Write a very long essay about albatrosses.", configuration: configuration)
            }

            try await Task.sleep(for: .seconds(3))
            let clock = ContinuousClock()
            let started = clock.now
            task.cancel()
            _ = try? await task.value

            #expect((clock.now - started) < .seconds(15))
        }
    }
}

@Suite(
    "Integration: structured output and attachments",
    .enabled(if: IntegrationGate.liveRunsEnabled, "Set AGENTICCLIKIT_LIVE=1 — this spends tokens"),
    .timeLimit(.minutes(10)),
    .serialized
)
struct StructuredAndAttachmentIntegrationTests {
    private func withScratchDirectory(_ body: (URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentickit-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(directory)
    }

    /// Every prompting adapter, against the record from the original request.
    @Test(
        "Each CLI enforces the schema and returns a decoded record",
        arguments: [CLIIdentifier.claudeCode, .codex, .antigravity]
    )
    func returnsDecodedRecords(cli: CLIIdentifier) async throws {
        let kit = AgenticCLIKit()
        let agent = try kit.agent(for: cli)
        try await agent.verifyReady()

        try await withScratchDirectory { directory in
            let response = try await agent.run(
                "Write a git commit message for this change: added a Swift library for driving agentic CLIs.",
                returning: CommitMessage.self,
                configuration: .readOnly(in: directory, timeout: .seconds(240))
            )

            #expect(!response.value.commitSubject.isEmpty)
            #expect(!response.value.commitDescription.isEmpty)
            // The schema said 50 characters; a little slack for models that
            // treat it as guidance.
            #expect(response.value.commitSubject.count < 80)
            print("\(cli): \(response.value.commitSubject)")
        }
    }

    @Test("A PDF on disk reaches the agent")
    func readsAttachedPDF() async throws {
        let adapter = ClaudeCode.Adapter()
        try await adapter.verifyReady()

        try await withScratchDirectory { directory in
            // A minimal but genuinely valid PDF containing one word.
            let pdf = directory.appendingPathComponent("secret.pdf")
            try Self.makePDF(containing: "ALBATROSS").write(to: pdf)

            var configuration = RunConfiguration(
                workingDirectory: directory,
                permissions: .readOnly,
                timeout: .seconds(240)
            )
            configuration.attachments = [.file(pdf, description: "a document with one word in it")]

            let response = try await adapter.run(
                "What single word does the attached document contain? Reply with only that word.",
                configuration: configuration
            )
            #expect(response.text.uppercased().contains("ALBATROSS"))
        }
    }

    @Test("A remote URL is downloaded and handed over as a local file")
    func downloadsRemoteAttachment() async throws {
        let adapter = ClaudeCode.Adapter()
        try await adapter.verifyReady()

        try await withScratchDirectory { directory in
            var configuration = RunConfiguration(
                workingDirectory: directory,
                permissions: .readOnly,
                timeout: .seconds(240)
            )
            // Stable, tiny, and text: enough to prove the file arrived.
            configuration.attachments = [
                .remote(URL(string: "https://raw.githubusercontent.com/apple/swift/main/README.md")!,
                        description: "the Swift README"),
            ]

            let response = try await adapter.run(
                "What project is the attached README for? Answer in one word.",
                configuration: configuration
            )
            #expect(response.text.lowercased().contains("swift"))
        }
    }

    @Test("Codex attaches an image with its native flag")
    func attachesImageToCodex() async throws {
        let adapter = Codex.Adapter()
        try await adapter.verifyReady()

        try await withScratchDirectory { directory in
            var configuration = RunConfiguration(
                workingDirectory: directory,
                permissions: .readOnly,
                timeout: .seconds(240)
            )
            configuration.attachments = [.data(Self.redSquarePNG, filename: "square.png")]

            let response = try await adapter.run(
                "What colour is the attached image? Reply with one word.",
                configuration: configuration
            )
            #expect(response.text.lowercased().contains("red"))
        }
    }

    // MARK: - Fixtures

    /// A hand-built one-page PDF; avoids depending on Quartz in tests.
    static func makePDF(containing word: String) -> Data {
        let content = "BT /F1 24 Tf 72 700 Td (\(word)) Tj ET"
        var objects: [String] = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] "
                + "/Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        ]

        var pdf = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(pdf.utf8.count)
            pdf += "\(index + 1) 0 obj\n\(object)\nendobj\n"
        }
        let xrefOffset = pdf.utf8.count
        pdf += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets {
            pdf += String(format: "%010d 00000 n \n", offset)
        }
        pdf += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xrefOffset)\n%%EOF\n"
        objects.removeAll()
        return Data(pdf.utf8)
    }

    /// An 8×8 solid red PNG.
    static let redSquarePNG: Data = Data(base64Encoded: """
    iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAYAAADED76LAAAAFklEQVR42mP8z8BQz0AEYBxVSF+FAP\
    5FDvcfRYWgAAAAAElFTkSuQmCC
    """)!
}
