import Foundation
import Testing

@testable import AgenticCLIKit

@Suite("Session stores")
struct SessionStoreTests {
    private func makeSession(
        _ id: String,
        cli: CLIIdentifier = .claudeCode,
        directory: String = "/repo",
        lastUsed: Date = Date()
    ) -> SessionReference {
        SessionReference(
            cli: cli,
            sessionID: id,
            workingDirectory: URL(fileURLWithPath: directory),
            createdAt: lastUsed,
            lastUsedAt: lastUsed
        )
    }

    private func withTemporaryStore(
        maximumAge: Duration? = .seconds(60 * 60 * 24 * 30),
        _ body: (FileSessionStore, URL) async throws -> Void
    ) async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentickit-sessions-\(UUID().uuidString)")
            .appendingPathComponent("sessions.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await body(FileSessionStore(fileURL: url, maximumAge: maximumAge), url)
    }

    @Test("Identity is scoped per CLI, so two agents can share an ID")
    func identityIncludesCLI() {
        let claude = makeSession("same-id", cli: .claudeCode)
        let codex = makeSession("same-id", cli: .codex)
        #expect(claude.id != codex.id)
    }

    @Test("In-memory store round-trips and orders by last use")
    func inMemoryRoundTrip() async throws {
        let store = InMemorySessionStore()
        let older = makeSession("old", lastUsed: Date(timeIntervalSinceNow: -3600))
        let newer = makeSession("new")

        try await store.save(older)
        try await store.save(newer)

        let all = try await store.sessions(for: nil)
        #expect(all.map(\.sessionID) == ["new", "old"])
        #expect(try await store.session(id: "old", cli: .claudeCode) == older)

        try await store.remove(older)
        #expect(try await store.sessions(for: nil).count == 1)
    }

    @Test("Filters by CLI and by working directory")
    func filtersByCLIAndDirectory() async throws {
        let store = InMemorySessionStore([
            makeSession("a", cli: .claudeCode, directory: "/one", lastUsed: Date(timeIntervalSinceNow: -10)),
            makeSession("b", cli: .claudeCode, directory: "/two"),
            makeSession("c", cli: .codex, directory: "/one"),
        ])

        #expect(try await store.sessions(for: .codex).map(\.sessionID) == ["c"])
        #expect(try await store.mostRecentSession(for: .claudeCode)?.sessionID == "b")
        // Directory scoping is what keeps CWD-bound CLIs from resuming the
        // wrong conversation.
        let scoped = try await store.mostRecentSession(
            for: .claudeCode,
            in: URL(fileURLWithPath: "/one")
        )
        #expect(scoped?.sessionID == "a")
    }

    @Test("File store survives a reload")
    func fileStoreSurvivesReload() async throws {
        try await withTemporaryStore { store, url in
            try await store.save(makeSession("persisted"))

            let reloaded = FileSessionStore(fileURL: url)
            let sessions = try await reloaded.sessions(for: nil)
            #expect(sessions.map(\.sessionID) == ["persisted"])
            #expect(sessions.first?.workingDirectory.path == "/repo")
        }
    }

    @Test("Prunes sessions past the maximum age")
    func prunesOldSessions() async throws {
        try await withTemporaryStore(maximumAge: .seconds(3600)) { store, url in
            try await store.save(makeSession("fresh"))
            try await store.save(makeSession("stale", lastUsed: Date(timeIntervalSinceNow: -7200)))

            // Pruning happens on load, so read through a new instance.
            let reloaded = FileSessionStore(fileURL: url, maximumAge: .seconds(3600))
            #expect(try await reloaded.sessions(for: nil).map(\.sessionID) == ["fresh"])
        }
    }

    /// A corrupt index must not take session recovery down with it — the CLI's
    /// own storage is still the source of truth.
    @Test("A corrupt index degrades to empty instead of throwing")
    func toleratesCorruptFile() async throws {
        try await withTemporaryStore { store, url in
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("this is not json".utf8).write(to: url)

            let sessions = try await FileSessionStore(fileURL: url).sessions(for: nil)
            #expect(sessions.isEmpty)

            // And it recovers: saving works afterwards.
            try await store.save(makeSession("after-corruption"))
            #expect(try await FileSessionStore(fileURL: url).sessions(for: nil).count == 1)
        }
    }

    @Test("Recording a response stores its session")
    func recordsResponseSession() async throws {
        let store = InMemorySessionStore()
        let response = AgentResponse(
            text: "done",
            session: makeSession("from-response"),
            exitCode: 0
        )

        let recorded = try await store.record(response)
        #expect(recorded?.sessionID == "from-response")
        #expect(try await store.sessions(for: nil).count == 1)

        // A response without a session is a no-op, not an error.
        #expect(try await store.record(AgentResponse(text: "x", exitCode: 0)) == nil)
    }

    @Test("Session references survive JSON encoding")
    func sessionReferencesAreCodable() throws {
        let session = makeSession("codable-check")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(SessionReference.self, from: try encoder.encode(session))
        #expect(decoded.sessionID == session.sessionID)
        #expect(decoded.cli == session.cli)
        #expect(decoded.workingDirectory == session.workingDirectory)
    }
}
