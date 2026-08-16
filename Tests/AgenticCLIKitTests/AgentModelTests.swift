import AgenticCLIKitTesting
import Foundation
import Testing

@testable import AgenticCLIKit

@Suite("Model discovery")
struct AgentModelTests {
    private let workingDirectory = URL(fileURLWithPath: "/tmp")

    // MARK: - Hand-maintained lists

    @Test("Maintained lists are non-empty and free of duplicate identifiers")
    func maintainedListsAreWellFormed() {
        for models in [ClaudeCode.Model.agentModels, Codex.Model.agentModels, Copilot.Model.agentModels] {
            #expect(!models.isEmpty)
            #expect(Set(models.map(\.id)).count == models.count)
            #expect(models.allSatisfy { !$0.id.isEmpty })
            // Exactly one default, or a picker has nothing to preselect.
            #expect(models.filter(\.isDefault).count == 1)
        }
    }

    @Test("Maintained entries are labelled as bundled, not as a live catalogue")
    func maintainedEntriesAreLabelled() {
        let models = ClaudeCode.Model.agentModels
        #expect(models.allSatisfy { $0.origin == .bundled })
        // Nothing here should claim to be an exhaustive list.
        #expect(!models.isCompleteCatalogue)
        #expect(models.allSatisfy { !$0.isAuthoritative })
    }

    @Test("Claude's default is the Opus alias, which tracks the latest release")
    func claudeDefaultIsAnAlias() {
        #expect(ClaudeCode.Model.default == .opus)
        #expect(ClaudeCode.Model.opus.isAlias)
        #expect(!ClaudeCode.Model.opus5.isAlias)
        #expect(ClaudeCode.Model.agentModels.defaultModel?.id == "opus")
    }

    @Test("Selecting a maintained model sets the identifier the CLI expects")
    func selectsModelByEnum() {
        var configuration = RunConfiguration(workingDirectory: workingDirectory, permissions: .readOnly)
        configuration.use(ClaudeCode.Model.opus5)
        #expect(configuration.model == "claude-opus-5")

        let codexConfiguration = configuration.using(Codex.Model.gpt54Codex)
        #expect(codexConfiguration.model == "gpt-5.4-codex")
    }

    /// The whole point of keeping `model` a plain `String`: a model released
    /// after this package was tagged must work without a library update.
    @Test("An unlisted model can still be used")
    func acceptsUnlistedModels() throws {
        let runner = RecordedProcessRunner(always: .output(""))
        let adapter = ClaudeCode.Adapter(runner: runner, locator: FakeExecutableLocator())

        var configuration = RunConfiguration(workingDirectory: workingDirectory, permissions: .readOnly)
        configuration.model = "claude-opus-9-unreleased"

        let arguments = try adapter.makeArguments(prompt: "x", session: nil, configuration: configuration)
        #expect(arguments.contains("claude-opus-9-unreleased"))
    }

    /// No model means no flag — the CLI falls back to whatever the user
    /// configured, rather than this library imposing a choice.
    @Test("No requested model means no model flag")
    func omitsModelFlagByDefault() throws {
        let runner = RecordedProcessRunner(always: .output(""))
        let configuration = RunConfiguration(workingDirectory: workingDirectory, permissions: .readOnly)
        #expect(configuration.model == nil)

        let claude = ClaudeCode.Adapter(runner: runner, locator: FakeExecutableLocator())
        #expect(!(try claude.makeArguments(prompt: "x", session: nil, configuration: configuration))
            .contains("--model"))

        let codex = Codex.Adapter(runner: runner, locator: FakeExecutableLocator())
        #expect(!(try codex.makeArguments(prompt: "x", session: nil, configuration: configuration))
            .contains("--model"))

        let antigravity = Antigravity.Adapter(runner: runner, locator: FakeExecutableLocator())
        #expect(!(try antigravity.makeArguments(prompt: "x", session: nil, configuration: configuration))
            .contains("--model"))
    }

    // MARK: - Claude: help-text aliases

    @Test("Parses the aliases out of the real `--model` help paragraph")
    func parsesClaudeHelpAliases() {
        // Verbatim from `claude --help` 2.1.224, wrapped exactly as it prints.
        let help = """
          --mcp-config <configs...>             Load MCP servers from JSON files or
                                                strings (space-separated)
          --model <model>                       Model for the current session. Provide
                                                an alias for the latest model (e.g.
                                                'fable', 'opus', or 'sonnet') or a
                                                model's full name (e.g.
                                                'claude-fable-5').
          -n, --name <name>                     Set a display name for this session
        """

        let aliases = ClaudeCode.Adapter.parseModelAliases(fromHelp: help)
        #expect(aliases == ["fable", "opus", "sonnet", "claude-fable-5"])
    }

    @Test("Returns nothing when the help text has no --model flag")
    func toleratesMissingModelFlag() {
        #expect(ClaudeCode.Adapter.parseModelAliases(fromHelp: "Usage: claude [options]").isEmpty)
    }

    @Test("Claude merges maintained entries with aliases the binary documents")
    func claudeMergesHelpAliases() async throws {
        let help = """
          --model <model>                       Model for the current session. Provide
                                                an alias for the latest model (e.g.
                                                'opus', or 'newalias').
        """
        let runner = RecordedProcessRunner(matching: ["--help": .output(help)])
        let adapter = ClaudeCode.Adapter(runner: runner, locator: FakeExecutableLocator())

        let models = try await adapter.availableModels()

        // The maintained list is the backbone…
        #expect(models.contains { $0.id == "claude-opus-5" && $0.origin == .bundled })
        // …and an alias only the installed binary knows about is added to it.
        let discovered = try #require(models.first { $0.id == "newalias" })
        #expect(discovered.origin == .documentation)
        // An alias already in the maintained list is not duplicated.
        #expect(models.filter { $0.id == "opus" }.count == 1)
    }

    // MARK: - Codex: configured default

    @Test("Reads the top-level model from config.toml")
    func parsesCodexConfiguredModel() {
        let toml = """
        model = "gpt-5.4"
        model_reasoning_effort = "medium"
        """
        #expect(Codex.Adapter.parseModel(fromTOML: toml) == "gpt-5.4")
    }

    /// `model` also appears inside profile tables; those describe other
    /// profiles, so reading one would report a model this run will not use.
    @Test("Ignores model keys inside profile tables")
    func ignoresSectionedModelKeys() {
        let toml = """
        model_reasoning_effort = "medium"

        [profiles.experimental]
        model = "some-other-model"
        """
        #expect(Codex.Adapter.parseModel(fromTOML: toml) == nil)
    }

    @Test("Tolerates a config with no model set")
    func toleratesMissingCodexModel() {
        #expect(Codex.Adapter.parseModel(fromTOML: "personality = \"pragmatic\"") == nil)
    }

    @Test("Codex marks the configured model as the default")
    func codexPrefersConfiguredModel() async throws {
        let runner = RecordedProcessRunner(always: .output(""))
        let adapter = Codex.Adapter(runner: runner, locator: FakeExecutableLocator())

        let models = try await adapter.availableModels()
        #expect(!models.isEmpty)
        // Whatever the machine reports, exactly one entry is preselected.
        #expect(models.filter(\.isDefault).count <= 1)
        #expect(models.contains { $0.id == Codex.Model.gpt54.id })
    }

    // MARK: - Antigravity: live catalogue

    @Test("Parses the tab-separated catalogue `agy models` prints")
    func parsesAntigravityCatalogue() {
        // Verbatim from `agy models`, including its progress line.
        let output = """
        Fetching available models...
        gemini-3.7-flash-high\tGemini 3.7 Flash (High)
        gemini-3.1-pro-low\tGemini 3.1 Pro (Low)
        claude-sonnet-4-6\tClaude Sonnet 4.6 (Thinking)
        """

        let models = Antigravity.Adapter.parseModels(output)
        #expect(models.count == 3)
        #expect(models[0].id == "gemini-3.7-flash-high")
        #expect(models[0].displayName == "Gemini 3.7 Flash (High)")
        // The progress line carries no tab and must not become a model.
        #expect(!models.contains { $0.id.contains("Fetching") })
    }

    @Test("Antigravity's catalogue is authoritative, so it needs no maintained list")
    func antigravityCatalogueIsAuthoritative() async throws {
        let output = "Fetching available models...\ngemini-3.7-flash-high\tGemini 3.7 Flash (High)\n"
        let runner = RecordedProcessRunner(matching: ["models": .output(output)])
        let adapter = Antigravity.Adapter(runner: runner, locator: FakeExecutableLocator())

        let models = try await adapter.availableModels()
        #expect(models.isCompleteCatalogue)
        #expect(models.allSatisfy { $0.origin == .catalog })
        #expect(runner.lastInvocation?.arguments == ["models"])
    }

    /// The catalogue needs credentials and the network; failing loudly beats
    /// returning a guess that looks authoritative.
    @Test("A failed catalogue lookup throws rather than inventing models")
    func antigravityFailsLoudly() async {
        let runner = RecordedProcessRunner(matching: ["models": .failure("Please sign in to continue")])
        let adapter = Antigravity.Adapter(runner: runner, locator: FakeExecutableLocator())

        do {
            _ = try await adapter.availableModels()
            Issue.record("Expected a failure")
        } catch let error as AgenticCLIError {
            guard case .notAuthenticated = error else {
                Issue.record("Expected .notAuthenticated, got \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    // MARK: - Capability

    @Test("A CLI without models refuses the request")
    func githubRefusesModelDiscovery() async {
        let adapter = StubAgent(capabilities: .prompting)
        #expect(!adapter.capabilities.contains(.modelDiscovery))

        await #expect(throws: AgenticCLIError.self) {
            try await adapter.availableModels()
        }
    }

    @Test("The facade skips CLIs that cannot report models")
    func facadeSkipsUnsupportedCLIs() async throws {
        let runner = RecordedProcessRunner { invocation in
            if invocation.arguments == ["models"] {
                return .output("gemini-3.7-flash-high\tGemini 3.7 Flash (High)\n")
            }
            return .output("")
        }
        let kit = AgenticCLIKit(agents: [
            Antigravity.Adapter(runner: runner, locator: FakeExecutableLocator()),
            StubAgent(capabilities: .prompting),
        ])

        let byCLI = await kit.availableModelsByCLI()
        #expect(byCLI[.antigravity]?.isEmpty == false)
        // A CLI with no models is omitted rather than failing the whole call.
        #expect(byCLI[.stub] == nil)
    }

    @Test("Every shipped adapter can report models")
    func promptingAdaptersReportModels() {
        let supported = Set(
            AgenticCLIKit().agents(supporting: .modelDiscovery).map(\.identifier)
        )
        #expect(supported == Set([CLIIdentifier.claudeCode, .codex, .copilot, .antigravity, .vibe]))
    }
}
