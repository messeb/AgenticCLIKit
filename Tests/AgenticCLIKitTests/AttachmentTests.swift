import AgenticCLIKitTesting
import Foundation
import Testing

@testable import AgenticCLIKit

@Suite("Attachments")
struct AttachmentTests {
    // MARK: - Helpers

    private func withScratchDirectory(_ body: (URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentickit-attachments-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(directory)
    }

    private func writeFile(_ contents: String, named name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func configuration(
        in directory: URL,
        attachments: [PromptAttachment] = []
    ) -> RunConfiguration {
        var configuration = RunConfiguration(workingDirectory: directory, permissions: .readOnly)
        configuration.attachments = attachments
        return configuration
    }

    private func prompt(from invocation: ProcessInvocation) -> String {
        // `claude` and `agy` put the prompt after their print flag; `codex`
        // takes it as the final positional argument.
        if let index = invocation.arguments.firstIndex(where: { $0 == "--print" || $0 == "-p" }),
           invocation.arguments.indices.contains(index + 1) {
            return invocation.arguments[index + 1]
        }
        return invocation.arguments.last ?? ""
    }

    // MARK: - Kind inference

    @Test(
        "Infers kind from the file extension",
        arguments: [
            ("scan.pdf", PromptAttachment.Kind.document),
            ("shot.PNG", .image),
            ("notes.md", .text),
            ("archive.bin", .other),
        ]
    )
    func infersKind(filename: String, expected: PromptAttachment.Kind) {
        #expect(PromptAttachment.file(URL(fileURLWithPath: "/tmp/\(filename)")).resolvedKind == expected)
    }

    @Test("An explicit kind wins over the extension")
    func explicitKindWins() {
        let attachment = PromptAttachment.file(URL(fileURLWithPath: "/tmp/scan.bin"), kind: .image)
        #expect(attachment.resolvedKind == .image)
    }

    // MARK: - Resolution

    @Test("Local files resolve to their own path")
    func resolvesLocalFiles() async throws {
        try await withScratchDirectory { directory in
            let file = try writeFile("hello", named: "notes.txt", in: directory)
            let workspace = try RunWorkspace()
            defer { workspace.destroy() }

            let resolved = try await AttachmentResolver().resolve(
                [.file(file, description: "the notes")],
                into: workspace,
                cli: .claudeCode
            )

            #expect(resolved.count == 1)
            #expect(resolved[0].url.standardizedFileURL == file.standardizedFileURL)
            #expect(resolved[0].description == "the notes")
            #expect(resolved[0].byteCount == 5)
        }
    }

    @Test("In-memory data is written into the run's scratch directory")
    func resolvesDataAttachments() async throws {
        let workspace = try RunWorkspace()
        defer { workspace.destroy() }

        let resolved = try await AttachmentResolver().resolve(
            [.data(Data("PNGDATA".utf8), filename: "shot.png")],
            into: workspace,
            cli: .codex
        )

        #expect(resolved[0].kind == .image)
        #expect(resolved[0].url.path.hasPrefix(workspace.directory.path))
        #expect(FileManager.default.fileExists(atPath: resolved[0].url.path))
    }

    /// A filename is caller-supplied data; it must not be able to write outside
    /// the scratch directory.
    @Test("Filenames cannot escape the scratch directory")
    func sanitisesFilenames() async throws {
        let workspace = try RunWorkspace()
        defer { workspace.destroy() }

        let resolved = try await AttachmentResolver().resolve(
            [.data(Data("x".utf8), filename: "../../escaped.txt")],
            into: workspace,
            cli: .claudeCode
        )

        #expect(resolved[0].url.deletingLastPathComponent().standardizedFileURL
            == workspace.directory.standardizedFileURL)
    }

    @Test("A missing file is reported clearly")
    func reportsMissingFile() async throws {
        let workspace = try RunWorkspace()
        defer { workspace.destroy() }
        let missing = URL(fileURLWithPath: "/definitely/not/here.pdf")

        do {
            _ = try await AttachmentResolver().resolve([.file(missing)], into: workspace, cli: .claudeCode)
            Issue.record("Expected a failure")
        } catch let error as AgenticCLIError {
            guard case .attachmentUnavailable = error else {
                Issue.record("Expected .attachmentUnavailable, got \(error)")
                return
            }
            #expect(error.localizedDescription.contains("here.pdf"))
        }
    }

    @Test("A directory is refused, with a pointer to the right option")
    func refusesDirectories() async throws {
        try await withScratchDirectory { directory in
            let workspace = try RunWorkspace()
            defer { workspace.destroy() }

            do {
                _ = try await AttachmentResolver().resolve(
                    [.file(directory)],
                    into: workspace,
                    cli: .claudeCode
                )
                Issue.record("Expected a failure")
            } catch let error as AgenticCLIError {
                #expect(error.localizedDescription.contains("additionalDirectories"))
            }
        }
    }

    @Test("Oversized attachments are refused before the run starts")
    func enforcesSizeLimit() async throws {
        try await withScratchDirectory { directory in
            let file = try writeFile(String(repeating: "x", count: 5000), named: "big.txt", in: directory)
            let workspace = try RunWorkspace()
            defer { workspace.destroy() }

            do {
                _ = try await AttachmentResolver(maximumByteCount: 1024).resolve(
                    [.file(file)],
                    into: workspace,
                    cli: .claudeCode
                )
                Issue.record("Expected a failure")
            } catch let error as AgenticCLIError {
                guard case let .attachmentTooLarge(_, byteCount, limit) = error else {
                    Issue.record("Expected .attachmentTooLarge, got \(error)")
                    return
                }
                #expect(byteCount == 5000)
                #expect(limit == 1024)
                #expect(error.recoverySuggestion != nil)
            }
        }
    }

    // MARK: - Remote URLs

    @Test("Remote URLs are downloaded by the kit before the run")
    func downloadsRemoteURLs() async throws {
        let workspace = try RunWorkspace()
        defer { workspace.destroy() }

        let resolved = try await AttachmentResolver(session: StubURLProtocol.makeSession()).resolve(
            [.remote(URL(string: "https://example.com/spec.pdf")!, description: "the spec")],
            into: workspace,
            cli: .claudeCode
        )

        #expect(resolved[0].kind == .document)
        #expect(resolved[0].origin?.absoluteString == "https://example.com/spec.pdf")
        // The agent reads a local copy, so a CLI without web access still works.
        #expect(resolved[0].url.path.hasPrefix(workspace.directory.path))
        #expect(try Data(contentsOf: resolved[0].url) == StubURLProtocol.body)
    }

    @Test("A failed download names the status code")
    func reportsDownloadFailures() async throws {
        let workspace = try RunWorkspace()
        defer { workspace.destroy() }

        do {
            _ = try await AttachmentResolver(session: StubURLProtocol.makeSession()).resolve(
                [.remote(URL(string: "https://example.com/missing.pdf")!)],
                into: workspace,
                cli: .claudeCode
            )
            Issue.record("Expected a failure")
        } catch let error as AgenticCLIError {
            #expect(error.localizedDescription.contains("404"))
        }
    }

    @Test("Non-HTTP URLs are refused")
    func refusesNonHTTPURLs() async throws {
        let workspace = try RunWorkspace()
        defer { workspace.destroy() }

        do {
            _ = try await AttachmentResolver().resolve(
                [.remote(URL(string: "ftp://example.com/file.pdf")!)],
                into: workspace,
                cli: .claudeCode
            )
            Issue.record("Expected a failure")
        } catch let error as AgenticCLIError {
            #expect(error.localizedDescription.contains("http"))
        }
    }

    // MARK: - Prompt and directory plumbing

    @Test("The preamble lists absolute paths and descriptions")
    func buildsPromptPreamble() {
        let preamble = ResolvedAttachment.promptPreamble(for: [
            ResolvedAttachment(
                url: URL(fileURLWithPath: "/docs/invoice.pdf"),
                kind: .document,
                description: "the invoice",
                byteCount: 10
            ),
            ResolvedAttachment(
                url: URL(fileURLWithPath: "/docs/shot.png"),
                kind: .image,
                byteCount: 20,
                origin: URL(string: "https://example.com/shot.png")
            ),
        ])

        #expect(preamble.contains("/docs/invoice.pdf — the invoice"))
        #expect(preamble.contains("/docs/shot.png — downloaded from https://example.com/shot.png"))
        #expect(preamble.contains("Read them before answering"))
        #expect(ResolvedAttachment.promptPreamble(for: []).isEmpty)
    }

    @Test("Only files outside the working directory need an access grant")
    func computesRequiredDirectories() {
        let workingDirectory = URL(fileURLWithPath: "/repo")
        let directories = ResolvedAttachment.requiredDirectories(
            for: [
                ResolvedAttachment(url: URL(fileURLWithPath: "/repo/docs/a.pdf"), kind: .document, byteCount: 1),
                ResolvedAttachment(url: URL(fileURLWithPath: "/elsewhere/b.pdf"), kind: .document, byteCount: 1),
                ResolvedAttachment(url: URL(fileURLWithPath: "/elsewhere/c.pdf"), kind: .document, byteCount: 1),
            ],
            workingDirectory: workingDirectory
        )

        // Inside the workspace already; deduplicated for the rest.
        #expect(directories.map(\.path) == ["/elsewhere"])
    }

    // MARK: - Adapter wiring

    @Test("Claude gets the attachment in the prompt and the directory granted")
    func claudeReceivesAttachments() async throws {
        try await withScratchDirectory { directory in
            try await withScratchDirectory { elsewhere in
                let file = try writeFile("invoice", named: "invoice.pdf", in: elsewhere)
                let runner = RecordedProcessRunner(always: try .fixture(Fixture.url(Fixture.claudeStream)))
                let adapter = ClaudeCode.Adapter(runner: runner, locator: FakeExecutableLocator())

                _ = try await adapter.run(
                    "Summarise it",
                    configuration: configuration(
                        in: directory,
                        attachments: [.file(file, description: "the invoice")]
                    )
                )

                let invocation = try #require(runner.lastInvocation)
                let sentPrompt = prompt(from: invocation)
                #expect(sentPrompt.contains(file.path))
                #expect(sentPrompt.contains("the invoice"))
                #expect(sentPrompt.hasSuffix("Summarise it"))
                #expect(invocation.arguments.contains("--add-dir"))
                #expect(invocation.arguments.contains(elsewhere.standardizedFileURL.path))
            }
        }
    }

    /// Codex is the only one of the three with a real image flag.
    @Test("Codex passes images with --image and documents by path")
    func codexUsesNativeImageFlag() async throws {
        try await withScratchDirectory { directory in
            let image = try writeFile("PNG", named: "shot.png", in: directory)
            let document = try writeFile("PDF", named: "spec.pdf", in: directory)
            let runner = RecordedProcessRunner(always: try .fixture(Fixture.url(Fixture.codexStream)))
            let adapter = Codex.Adapter(runner: runner, locator: FakeExecutableLocator())

            _ = try await adapter.run(
                "Compare them",
                configuration: configuration(
                    in: directory,
                    attachments: [.file(image), .file(document)]
                )
            )

            let invocation = try #require(runner.lastInvocation)
            let imageIndex = try #require(invocation.arguments.firstIndex(of: "--image"))
            #expect(invocation.arguments[imageIndex + 1] == image.standardizedFileURL.path)
            // The document is not an image, so it travels in the prompt.
            #expect(prompt(from: invocation).contains(document.path))
        }
    }

    @Test("Antigravity receives attachments through the prompt")
    func antigravityReceivesAttachments() async throws {
        try await withScratchDirectory { directory in
            let file = try writeFile("notes", named: "notes.md", in: directory)
            let runner = RecordedProcessRunner(always: try .fixture(Fixture.url(Fixture.antigravityStream)))
            let adapter = Antigravity.Adapter(runner: runner, locator: FakeExecutableLocator())

            _ = try await adapter.run(
                "Summarise it",
                configuration: configuration(in: directory, attachments: [.file(file)])
            )

            #expect(prompt(from: try #require(runner.lastInvocation)).contains(file.path))
        }
    }

    @Test("A CLI that cannot read files refuses attachments")
    func refusesAttachmentsWithoutCapability() async throws {
        try await withScratchDirectory { directory in
            let file = try writeFile("x", named: "a.txt", in: directory)
            let adapter = CapabilityFreeAgent()
            #expect(!adapter.capabilities.contains(.fileAttachments))

            await #expect(throws: AgenticCLIError.self) {
                try await adapter.run(
                    "x",
                    configuration: configuration(in: directory, attachments: [.file(file)])
                )
            }
        }
    }

    @Test("The scratch directory is removed after the run")
    func cleansUpAfterTheRun() async throws {
        try await withScratchDirectory { directory in
            let runner = RecordedProcessRunner(always: try .fixture(Fixture.url(Fixture.claudeStream)))
            let adapter = ClaudeCode.Adapter(runner: runner, locator: FakeExecutableLocator())

            _ = try await adapter.run(
                "Summarise it",
                configuration: configuration(
                    in: directory,
                    attachments: [.data(Data("temp".utf8), filename: "temp.txt")]
                )
            )

            let sentPrompt = prompt(from: try #require(runner.lastInvocation))
            let path = try #require(
                sentPrompt.split(separator: "\n")
                    .first { $0.contains("temp.txt") }?
                    .split(separator: " ")
                    .first { $0.hasPrefix("/") }
                    .map(String.init)
            )
            #expect(!FileManager.default.fileExists(atPath: path))
        }
    }
}

/// Serves a fixed response so the download path is exercised without network.
///
/// The status code comes from the requested path rather than shared state,
/// because tests in a suite run concurrently and a mutable static would let one
/// test's 404 leak into another's request.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    static let body = Data("%PDF-1.4 stub".utf8)

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let isMissing = request.url?.path.contains("missing") == true
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: isMissing ? 404 : 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/pdf"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// A process-backed adapter that declares no capabilities at all.
///
/// The refusal it exercises lives in ``ProcessBackedCLI/prepareRun``, shared by
/// every adapter — and every shipped adapter now reads files, so testing that
/// branch needs a CLI that does not. Keeping the double here, rather than in
/// `AgenticCLIKitTesting`, is deliberate: `prepareRun` is internal, so only a
/// `@testable` consumer can reach it.
private struct CapabilityFreeAgent: ProcessBackedCLI {
    static let identifier = CLIIdentifier("capability-free")

    let runner: any ProcessRunner = RecordedProcessRunner(always: .output(""))
    let locator: any ExecutableLocating = FakeExecutableLocator()

    var displayName: String { "Capability-free" }
    var executableName: String { "capability-free" }
    var installHint: String { "Not a real CLI" }
    var loginCommand: String { "true" }
    var minimumSupportedVersion: SemanticVersion { SemanticVersion(1, 0, 0) }
    var capabilities: CLICapabilities { [] }
    var environmentPolicy: EnvironmentPolicy { .base }

    func authenticationStatus() async -> AuthenticationStatus {
        .authenticated(AuthenticatedAccount(method: .keychain))
    }

    func stream(_ prompt: String, configuration: RunConfiguration) -> AgentEventStream {
        AgentEventStream { continuation in
            let task = Task {
                do {
                    let prepared = try await prepareRun(prompt: prompt, configuration: configuration)
                    prepared.workspace?.destroy()
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func stream(
        resuming session: SessionReference,
        prompt: String,
        configuration: RunConfiguration
    ) -> AgentEventStream {
        stream(prompt, configuration: configuration)
    }
}
