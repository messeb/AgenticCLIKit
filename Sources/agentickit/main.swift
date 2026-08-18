import AgenticCLIKit
import Foundation

private extension Duration {
    /// Fractional seconds, for display. The library keeps its own copy of this
    /// internal to avoid publishing an extension on a standard-library type.
    var elapsedSeconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

/// A small driver for the library, useful as both a smoke test and a worked
/// example of the API.
///
/// Argument parsing is hand-rolled to keep the package dependency-free.
///
///     agentickit health
///     agentickit run claude-code "Summarise this directory" [--permissions readOnly] [--stream]
///     agentickit resume claude-code <session-id> "And the tests?"
///     agentickit continue codex "Keep going"
///     agentickit sessions
///     agentickit commit-message claude-code --dir ~/project
///     agentickit run claude-code "Summarise it" --attach report.pdf --attach https://example.com/spec.pdf

@main
struct AgenticKitCommand {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let command = arguments.first else {
            print(usage)
            exit(2)
        }

        do {
            switch command {
            case "health": try await health()
            case "run": try await run(Array(arguments.dropFirst()))
            case "resume": try await resume(Array(arguments.dropFirst()))
            case "continue": try await continueSession(Array(arguments.dropFirst()))
            case "commit-message": try await commitMessage(Array(arguments.dropFirst()))
            case "models": try await models(Array(arguments.dropFirst()))
            case "sessions": try await sessions()
            case "help", "--help", "-h": print(usage)
            default:
                FileHandle.standardError.write(Data("Unknown command: \(command)\n\n\(usage)\n".utf8))
                exit(2)
            }
        } catch let error as AgenticCLIError {
            var message = "error: \(error.localizedDescription)\n"
            if let suggestion = error.recoverySuggestion {
                message += "hint:  \(suggestion)\n"
            }
            FileHandle.standardError.write(Data(message.utf8))
            exit(1)
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(1)
        }
    }

    static let usage = """
    agentickit — drive locally installed agentic CLIs

    USAGE
      agentickit health
      agentickit run <cli> <prompt> [--permissions <policy>] [--model <name>] [--stream] [--dir <path>]
      agentickit resume <cli> <session-id> <prompt> [options]
      agentickit continue <cli> <prompt> [options]
      agentickit commit-message <cli> [--dir <path>]
      agentickit models [<cli>]
      agentickit sessions

    ATTACHMENTS
      --attach <path-or-url>   repeatable; remote URLs are downloaded first

    CLIs
      claude-code, codex, copilot, antigravity, vibe, grok

    POLICIES
      planOnly (default), readOnly, acceptingEdits, unsafeBypassAll
    """

    // MARK: - Shared state

    /// Sessions persist in Application Support so `resume` works across runs —
    /// which is the whole point of the feature.
    static func makeKit() throws -> AgenticCLIKit {
        AgenticCLIKit(
            sessionStore: try FileSessionStore.applicationSupport(subdirectory: "agentickit-demo")
        )
    }

    // MARK: - Commands

    static func health() async throws {
        let clock = ContinuousClock()
        let started = clock.now
        let report = try await makeKit().healthReport()
        print(report.formattedSummary())
        print("\nprobed in \(String(format: "%.2f", (clock.now - started).elapsedSeconds))s")
    }

    static func run(_ arguments: [String]) async throws {
        let options = try Options(arguments, positionalCount: 2)
        let kit = try makeKit()
        let identifier = CLIIdentifier(options.positional[0])
        let prompt = options.positional[1]

        if options.streams {
            try await printStream(
                kit.stream(prompt, using: identifier, configuration: options.configuration)
            )
        } else {
            let response = try await kit.run(prompt, using: identifier, configuration: options.configuration)
            printResponse(response)
        }
    }

    static func resume(_ arguments: [String]) async throws {
        let options = try Options(arguments, positionalCount: 3)
        let kit = try makeKit()
        let identifier = CLIIdentifier(options.positional[0])
        let sessionID = options.positional[1]

        let stored = try await kit.sessionStore.session(id: sessionID, cli: identifier)
        let session = stored ?? SessionReference(
            cli: identifier,
            sessionID: sessionID,
            workingDirectory: options.configuration.workingDirectory
        )

        let response = try await kit.resume(
            session,
            with: options.positional[2],
            configuration: options.configuration
        )
        printResponse(response)
    }

    static func continueSession(_ arguments: [String]) async throws {
        let options = try Options(arguments, positionalCount: 2)
        let kit = try makeKit()
        let response = try await kit.continueOrStart(
            options.positional[1],
            using: CLIIdentifier(options.positional[0]),
            configuration: options.configuration
        )
        printResponse(response)
    }

    /// The worked example for structured output: a record, not prose.
    struct CommitMessage: StructuredOutput {
        let commitSubject: String
        let commitDescription: String

        static let outputSchema = JSONSchema.object([
            "commitSubject": .string("Imperative mood, at most 50 characters"),
            "commitDescription": .string("Body explaining why the change was made"),
        ])
    }

    static func commitMessage(_ arguments: [String]) async throws {
        let options = try Options(arguments, positionalCount: 1)
        var configuration = options.configuration
        // `agy` cannot combine plan mode with a schema, and read-only is the
        // right posture for reading a diff anyway.
        configuration.permissions = .readOnly

        let response = try await makeKit().run(
            "Read the uncommitted changes in this repository and write a commit message for them.",
            returning: CommitMessage.self,
            using: CLIIdentifier(options.positional[0]),
            configuration: configuration
        )

        print(response.value.commitSubject)
        print()
        print(response.value.commitDescription)
        printFooter(response.response)
    }

    /// Shows what each CLI reports, and where the answer came from.
    static func models(_ arguments: [String]) async throws {
        let kit = try makeKit()

        if let name = arguments.first {
            printModels(try await kit.availableModels(for: CLIIdentifier(name)), for: CLIIdentifier(name))
            return
        }

        let byCLI = await kit.availableModelsByCLI()
        guard !byCLI.isEmpty else {
            print("No installed CLI could report its models.")
            return
        }
        for cli in byCLI.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            printModels(byCLI[cli] ?? [], for: cli)
            print()
        }
    }

    static func printModels(_ models: [AgentModel], for cli: CLIIdentifier) {
        let provenance = models.isCompleteCatalogue
            ? "complete list, reported by the CLI"
            : "may be incomplete — any model identifier is still accepted"
        print("\(cli) (\(provenance))")

        for model in models {
            var line = "  \(model.isDefault ? "*" : " ") \(model.id)"
            if let displayName = model.displayName { line += "  \(displayName)" }
            line += "  [\(model.origin.rawValue)]"
            print(line)
            if let summary = model.summary { print("      \(summary)") }
        }
    }

    static func sessions() async throws {
        let stored = try await makeKit().sessionStore.sessions(for: nil)
        guard !stored.isEmpty else {
            print("No stored sessions.")
            return
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        for session in stored {
            print("\(session.cli)  \(session.sessionID)  \(formatter.string(from: session.lastUsedAt))")
            print("    \(session.workingDirectory.path)")
        }
    }

    // MARK: - Output

    static func printResponse(_ response: AgentResponse) {
        print(response.text)
        printFooter(response)
    }

    static func printFooter(_ response: AgentResponse) {
        var footer: [String] = []
        if let session = response.session { footer.append("session \(session.sessionID)") }
        if let usage = response.usage {
            if let total = usage.totalTokens { footer.append("\(total) tokens") }
            if let cost = usage.costUSD { footer.append(String(format: "$%.4f", cost)) }
        }
        footer.append(String(format: "%.1fs", response.duration.elapsedSeconds))
        FileHandle.standardError.write(Data("\n— \(footer.joined(separator: " · "))\n".utf8))
    }

    static func printStream(_ stream: AgentEventStream) async throws {
        for try await event in stream {
            switch event {
            case let .sessionStarted(session):
                FileHandle.standardError.write(Data("[session \(session.sessionID)]\n".utf8))
            case let .assistantTextDelta(text), let .assistantMessage(text):
                print(text, terminator: "")
                fflush(stdout)
            case let .toolUseRequested(tool):
                FileHandle.standardError.write(Data("\n[tool \(tool.name)]\n".utf8))
            case let .finished(response):
                print()
                printResponse(response)
            case let .diagnostic(line):
                FileHandle.standardError.write(Data("[stderr] \(line)\n".utf8))
            default:
                continue
            }
        }
    }

    // MARK: - Options

    struct Options {
        var positional: [String] = []
        var configuration: RunConfiguration
        var streams = false

        init(_ arguments: [String], positionalCount: Int) throws {
            var directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            var permissions = PermissionPolicy.planOnly
            var model: String?
            var timeout = Duration.seconds(600)
            var positional: [String] = []
            var streams = false
            var attachments: [PromptAttachment] = []

            var index = 0
            while index < arguments.count {
                let argument = arguments[index]
                func value() throws -> String {
                    index += 1
                    guard index < arguments.count else {
                        throw OptionError.missingValue(argument)
                    }
                    return arguments[index]
                }

                switch argument {
                case "--dir": directory = URL(fileURLWithPath: try value())
                case "--model": model = try value()
                case "--timeout": timeout = .seconds(Double(try value()) ?? 600)
                case "--stream": streams = true
                case "--attach": attachments.append(Self.attachment(from: try value()))
                case "--permissions": permissions = try Self.policy(named: try value())
                default: positional.append(argument)
                }
                index += 1
            }

            guard positional.count >= positionalCount else {
                throw OptionError.missingArguments(expected: positionalCount, got: positional.count)
            }

            self.positional = positional
            self.streams = streams
            self.configuration = RunConfiguration(
                workingDirectory: directory,
                permissions: permissions,
                model: model,
                timeout: timeout,
                attachments: attachments
            )
        }

        /// Anything with an http(s) scheme is fetched; everything else is a path.
        static func attachment(from value: String) -> PromptAttachment {
            if let url = URL(string: value), let scheme = url.scheme?.lowercased(),
               scheme == "http" || scheme == "https" {
                return .remote(url)
            }
            return .file(URL(fileURLWithPath: (value as NSString).expandingTildeInPath))
        }

        static func policy(named name: String) throws -> PermissionPolicy {
            switch name {
            case "planOnly", "plan": return .planOnly
            case "readOnly", "read": return .readOnly
            case "acceptingEdits", "edits": return .acceptingEdits
            case "unsafeBypassAll": return .unsafeBypassAll
            default: throw OptionError.unknownPolicy(name)
            }
        }

        enum OptionError: Error, LocalizedError {
            case missingValue(String)
            case missingArguments(expected: Int, got: Int)
            case unknownPolicy(String)

            var errorDescription: String? {
                switch self {
                case let .missingValue(flag): return "\(flag) needs a value"
                case let .missingArguments(expected, got): return "expected \(expected) arguments, got \(got)"
                case let .unknownPolicy(name): return "unknown permission policy: \(name)"
                }
            }
        }
    }
}
