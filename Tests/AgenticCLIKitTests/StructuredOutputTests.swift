import AgenticCLIKitTesting
import Foundation
import Testing

@testable import AgenticCLIKit

/// The record from the API request that prompted this feature.
struct CommitMessage: StructuredOutput, Equatable {
    let commitSubject: String
    let commitDescription: String

    static let outputSchema = JSONSchema.object([
        "commitSubject": .string("Imperative mood, at most 50 characters"),
        "commitDescription": .string("Body explaining why the change was made"),
    ])
}

@Suite("JSON Schema")
struct JSONSchemaTests {
    @Test("Objects require every property and reject unknown keys")
    func encodesObjects() throws {
        let json = try CommitMessage.outputSchema.jsonString()
        let decoded = try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )

        #expect(decoded["type"] as? String == "object")
        #expect(decoded["additionalProperties"] as? Bool == false)
        #expect(decoded["required"] as? [String] == ["commitDescription", "commitSubject"])

        let properties = try #require(decoded["properties"] as? [String: Any])
        let subject = try #require(properties["commitSubject"] as? [String: Any])
        #expect(subject["type"] as? String == "string")
        #expect(subject["description"] as? String == "Imperative mood, at most 50 characters")
    }

    /// A field the model may omit has to leave the required list, or the
    /// provider rejects a perfectly valid answer.
    @Test("Optional properties drop out of `required`")
    func optionalPropertiesAreNotRequired() throws {
        let schema = JSONSchema.object([
            "title": .string(),
            "subtitle": .optional(.string("Only when there is one")),
        ])
        let decoded = try #require(
            try JSONSerialization.jsonObject(with: try schema.jsonData()) as? [String: Any]
        )

        #expect(decoded["required"] as? [String] == ["title"])
        let properties = try #require(decoded["properties"] as? [String: Any])
        // The property itself is still described, just not mandatory.
        #expect((properties["subtitle"] as? [String: Any])?["type"] as? String == "string")
    }

    @Test("Encodes enums, arrays, and nested objects")
    func encodesCompoundTypes() throws {
        let schema = JSONSchema.object([
            "severity": .string("How bad", oneOf: ["low", "high"]),
            "files": .array(of: .object(["path": .string(), "lines": .integer()])),
            "confident": .boolean(),
            "score": .number(),
        ])
        let decoded = try #require(
            try JSONSerialization.jsonObject(with: try schema.jsonData()) as? [String: Any]
        )
        let properties = try #require(decoded["properties"] as? [String: Any])

        #expect((properties["severity"] as? [String: Any])?["enum"] as? [String] == ["low", "high"])
        let files = try #require(properties["files"] as? [String: Any])
        #expect(files["type"] as? String == "array")
        let items = try #require(files["items"] as? [String: Any])
        #expect((items["required"] as? [String]) == ["lines", "path"])
        #expect((properties["confident"] as? [String: Any])?["type"] as? String == "boolean")
        #expect((properties["score"] as? [String: Any])?["type"] as? String == "number")
    }

    @Test("Hand-written schemas pass through untouched")
    func passesThroughRawSchemas() throws {
        let schema = JSONSchema.raw(json: #"{"type":"object","x-vendor":true}"#)
        let decoded = try #require(
            try JSONSerialization.jsonObject(with: try schema.jsonData()) as? [String: Any]
        )
        #expect(decoded["x-vendor"] as? Bool == true)
    }

    /// Stable bytes keep recorded transcripts from churning.
    @Test("Serialisation is deterministic")
    func isDeterministic() throws {
        let first = try CommitMessage.outputSchema.jsonString()
        let second = try CommitMessage.outputSchema.jsonString()
        #expect(first == second)
    }
}

@Suite("Finding JSON in an agent's reply")
struct StructuredOutputExtractionTests {
    @Test("Reads bare JSON")
    func readsBareJSON() {
        #expect(StructuredOutputExtraction.firstJSONValue(in: #"{"a":1}"#) == #"{"a":1}"#)
    }

    @Test("Reads JSON out of a fenced code block")
    func readsFencedJSON() {
        let text = """
        Here you go:

        ```json
        {"commitSubject": "Add thing"}
        ```

        Hope that helps!
        """
        #expect(StructuredOutputExtraction.firstJSONValue(in: text) == #"{"commitSubject": "Add thing"}"#)
    }

    @Test("Reads JSON that follows prose")
    func readsJSONAfterProse() {
        let text = "I have prepared a plan.\n{\"commitSubject\":\"Add thing\"}\n"
        #expect(StructuredOutputExtraction.firstJSONValue(in: text) == #"{"commitSubject":"Add thing"}"#)
    }

    /// A brace inside a string must not end the object early — the commit
    /// bodies this feature exists for routinely contain punctuation.
    @Test("Ignores braces inside strings")
    func ignoresBracesInsideStrings() {
        let text = #"{"body":"use {} for empty, and \"quotes\" too"}"#
        #expect(StructuredOutputExtraction.firstJSONValue(in: text) == text)
    }

    @Test("Handles nested objects and arrays")
    func handlesNesting() {
        let text = #"prefix {"a":{"b":[1,2,{"c":3}]}} suffix"#
        #expect(StructuredOutputExtraction.firstJSONValue(in: text) == #"{"a":{"b":[1,2,{"c":3}]}}"#)
    }

    @Test("Returns nil when there is no JSON")
    func returnsNilWithoutJSON() {
        #expect(StructuredOutputExtraction.firstJSONValue(in: "Sorry, I cannot help with that.") == nil)
    }
}

@Suite("Structured runs")
struct StructuredRunTests {
    private let workingDirectory = URL(fileURLWithPath: "/tmp/agentickit-tests")

    private func configuration() -> RunConfiguration {
        RunConfiguration(workingDirectory: workingDirectory, permissions: .readOnly)
    }

    // MARK: - Claude

    @Test("Claude receives the schema inline and returns a decoded record")
    func claudeDecodesStructuredOutput() async throws {
        let runner = RecordedProcessRunner(always: try .fixture(Fixture.url(Fixture.claudeSchema)))
        let adapter = ClaudeCode.Adapter(runner: runner, locator: FakeExecutableLocator())

        let response = try await adapter.run(
            "Write a commit message",
            returning: CommitMessage.self,
            configuration: configuration()
        )

        #expect(response.value.commitSubject == "feat: add Swift library for driving agentic CLIs")
        #expect(response.value.commitDescription.contains("Swift package"))

        // The plain response is still reachable through the wrapper.
        #expect(response.session != nil)
        #expect(response.usage?.costUSD != nil)
        #expect(response.response.exitCode == 0)

        let arguments = try #require(runner.lastInvocation?.arguments)
        let schemaIndex = try #require(arguments.firstIndex(of: "--json-schema"))
        #expect(arguments[schemaIndex + 1].contains("commitSubject"))
    }

    // MARK: - Codex

    @Test("Codex receives the schema as a file that exists during the run")
    func codexWritesSchemaFile() async throws {
        // Captured while the process is "running", because the scratch
        // directory is deleted as soon as the run ends.
        let schemaFileExisted = Mutex(false)
        let runner = RecordedProcessRunner { invocation in
            if let index = invocation.arguments.firstIndex(of: "--output-schema") {
                let path = invocation.arguments[index + 1]
                schemaFileExisted.withLock { $0 = FileManager.default.fileExists(atPath: path) }
            }
            return (try? .fixture(Fixture.url(Fixture.codexSchema))) ?? .output("")
        }
        let adapter = Codex.Adapter(runner: runner, locator: FakeExecutableLocator())

        let response = try await adapter.run(
            "Write a commit message",
            returning: CommitMessage.self,
            configuration: configuration()
        )

        #expect(schemaFileExisted.withLock { $0 }, "codex --output-schema needs the file to exist")
        #expect(response.value.commitSubject == "Add Swift library for agentic CLIs")
    }

    @Test("Codex cleans up its scratch directory afterwards")
    func codexCleansUpScratchDirectory() async throws {
        let capturedPath = Mutex<String?>(nil)
        let runner = RecordedProcessRunner { invocation in
            if let index = invocation.arguments.firstIndex(of: "--output-schema") {
                capturedPath.withLock { $0 = invocation.arguments[index + 1] }
            }
            return (try? .fixture(Fixture.url(Fixture.codexSchema))) ?? .output("")
        }
        let adapter = Codex.Adapter(runner: runner, locator: FakeExecutableLocator())

        _ = try await adapter.run("x", returning: CommitMessage.self, configuration: configuration())

        let path = try #require(capturedPath.withLock { $0 })
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    // MARK: - Antigravity

    /// The reason decoding prefers the structured field: `agy` puts a plan, a
    /// file link, *and* the JSON into its response text. Parsing that text
    /// first would hand the caller the prose.
    @Test("Antigravity decodes from structured_output, not from its chatty text")
    func antigravityPrefersStructuredField() async throws {
        let runner = RecordedProcessRunner(always: try .fixture(Fixture.url(Fixture.antigravitySchema)))
        let adapter = Antigravity.Adapter(runner: runner, locator: FakeExecutableLocator())

        let response = try await adapter.run(
            "Write a commit message",
            returning: CommitMessage.self,
            configuration: configuration()
        )

        #expect(response.value.commitSubject == "feat: add Swift driver commit message options")
        #expect(response.value.commitDescription.hasPrefix("Created commit message options"))
        // The text really does contain the prose that would have been returned.
        #expect(response.text.contains("I have prepared a plan"))
    }

    // MARK: - Capability enforcement

    @Test("A CLI that cannot enforce a schema refuses the run")
    func refusesWithoutNativeSchemaSupport() async {
        let adapter = StubAgent(capabilities: [.prompting, .sessions])
        #expect(!adapter.capabilities.contains(.nativeOutputSchema))

        do {
            _ = try await adapter.run("x", returning: CommitMessage.self, configuration: configuration())
            Issue.record("Expected a refusal")
        } catch let error as AgenticCLIError {
            guard case let .unsupportedCapability(_, capability) = error else {
                Issue.record("Expected .unsupportedCapability, got \(error)")
                return
            }
            #expect(capability.contains(.nativeOutputSchema))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    /// Copilot and Vibe are the exceptions among the shipped adapters: they prompt and
    /// streams JSON, but has no flag that constrains the reply to a schema, so
    /// it is excluded rather than served by a best-effort prompt instruction.
    @Test("Only adapters that can enforce a schema are offered for typed runs")
    func promptingAdaptersSupportSchemas() {
        let kit = AgenticCLIKit()
        let supported: Set<CLIIdentifier> = Set(kit.structuredOutputAgents.map(\.identifier))
        #expect(supported == Set([CLIIdentifier.claudeCode, .codex, .antigravity, .grok]))
        #expect(!supported.contains(.copilot))
    }

    // MARK: - Failure reporting

    @Test("A reply that does not match the record reports the offending text")
    func reportsDecodingFailures() async {
        let line = #"{"type":"result","subtype":"success","session_id":"s1","result":"I could not do that."}"#
        let runner = RecordedProcessRunner(always: .output(line + "\n"))
        let adapter = ClaudeCode.Adapter(runner: runner, locator: FakeExecutableLocator())

        do {
            _ = try await adapter.run("x", returning: CommitMessage.self, configuration: configuration())
            Issue.record("Expected a failure")
        } catch let error as AgenticCLIError {
            guard case let .structuredOutputFailed(_, text) = error else {
                Issue.record("Expected .structuredOutputFailed, got \(error)")
                return
            }
            #expect(text.contains("I could not do that."))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Resuming a session can also return a record")
    func resumesWithStructuredOutput() async throws {
        let runner = RecordedProcessRunner(always: try .fixture(Fixture.url(Fixture.claudeSchema)))
        let adapter = ClaudeCode.Adapter(runner: runner, locator: FakeExecutableLocator())
        let session = SessionReference(
            cli: .claudeCode,
            sessionID: "s1",
            workingDirectory: workingDirectory
        )

        let response = try await adapter.resume(
            session,
            with: "Rewrite it shorter",
            returning: CommitMessage.self,
            configuration: configuration()
        )

        #expect(!response.value.commitSubject.isEmpty)
        let arguments = try #require(runner.lastInvocation?.arguments)
        #expect(arguments.contains("--resume"))
        #expect(arguments.contains("--json-schema"))
    }

    @Test("Schemas can be used without a Swift type to decode into")
    func supportsSchemaWithoutDecoding() async throws {
        let runner = RecordedProcessRunner(always: try .fixture(Fixture.url(Fixture.claudeSchema)))
        let adapter = ClaudeCode.Adapter(runner: runner, locator: FakeExecutableLocator())

        var configuration = configuration()
        configuration.outputSchema = CommitMessage.outputSchema
        let response = try await adapter.run("x", configuration: configuration)

        #expect(response.structuredOutput != nil)
        #expect(try response.decode(as: CommitMessage.self).commitSubject.contains("Swift library"))
    }
}
