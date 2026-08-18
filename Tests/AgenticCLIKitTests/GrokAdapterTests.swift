import AgenticCLIKitTesting
import Foundation
import Testing

@testable import AgenticCLIKit

@Suite("Grok adapter")
struct GrokAdapterTests {
    private let workingDirectory = URL(fileURLWithPath: "/tmp/agentickit-tests")

    private func adapter() -> Grok.Adapter {
        Grok.Adapter(runner: RecordedProcessRunner(always: .output("")), locator: FakeExecutableLocator())
    }

    private func configuration(_ permissions: PermissionPolicy = .readOnly) -> RunConfiguration {
        RunConfiguration(workingDirectory: workingDirectory, permissions: permissions)
    }

    @Test("Uses Grok's documented headless streaming invocation")
    func buildsArguments() throws {
        var config = configuration(.acceptingEdits)
        config.model = "grok-4.6"
        config.maximumTurns = 3
        config.systemPromptAppendix = "Be concise."
        let arguments = try adapter().makeArguments(prompt: "hello", session: nil, configuration: config)

        #expect(arguments.starts(with: ["--no-auto-update", "--single", "hello", "--output-format", "streaming-json"]))
        #expect(arguments.contains("acceptEdits"))
        #expect(arguments.contains("workspace"))
        #expect(arguments.contains("grok-4.6"))
        #expect(arguments.contains("3"))
        #expect(arguments.contains("Be concise."))
    }

    @Test("Maps safe policies without widening permissions")
    func mapsPermissions() throws {
        let adapter = adapter()
        #expect(try adapter.permissionArguments(for: .planOnly) == ["--permission-mode", "plan"])
        #expect(try adapter.permissionArguments(for: .readOnly) == ["--sandbox", "read-only", "--tools", "Read,Grep,WebFetch,WebSearch"])
        #expect(try adapter.permissionArguments(for: .unsafeBypassAll) == ["--always-approve"])
    }

    @Test("Parses Grok's model catalogue")
    func parsesModels() {
        let models = Grok.Adapter.parseModels("""
        Default model: grok-4.6

        Available models:
          * grok-4.6 (default)
          - grok-4.5
        """)
        #expect(models.map(\.id) == ["grok-4.6", "grok-4.5"])
        #expect(models.defaultModel?.id == "grok-4.6")
        #expect(models.isCompleteCatalogue)
    }

    @Test("Translates documented streaming events")
    func translatesStream() async throws {
        let recording = RecordedProcessRunner.Recording.output("""
        {"type":"thought","data":"Checking files"}
        {"type":"tool_call","toolCallId":"call-1","toolName":"read_file","rawInput":{"path":"README.md"}}
        {"type":"tool_call_update","toolCallId":"call-1","status":"completed","rawOutput":{"lines":1}}
        {"type":"text","data":"OK"}
        {"type":"end","stopReason":"end_turn","sessionId":"s-1","usage":{"input_tokens":10,"output_tokens":2,"reasoning_tokens":3}}
        """)
        let tested = Grok.Adapter(runner: RecordedProcessRunner(always: recording), locator: FakeExecutableLocator())
        let events = try await tested.stream("hello", configuration: configuration()).allEvents()

        #expect(events.contains { if case .reasoningDelta("Checking files") = $0 { true } else { false } })
        #expect(events.contains { if case let .toolUseRequested(tool) = $0 { tool.name == "read_file" } else { false } })
        let response = try #require(events.compactMap(\.response).first)
        #expect(response.text == "OK")
        #expect(response.session?.sessionID == "s-1")
        #expect(response.usage?.reasoningTokens == 3)
    }
}
