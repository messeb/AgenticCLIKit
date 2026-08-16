import Foundation

/// Every failure the kit reports, mapped from exit codes, output parsing, and
/// process management.
///
/// Adapters translate CLI-specific failure signals into these cases so host
/// apps can branch on meaning rather than on exit-code trivia.
public enum AgenticCLIError: Error, Sendable {
    /// The executable could not be found on `PATH` or in the well-known
    /// installation locations.
    case notInstalled(CLIIdentifier, installHint: String)
    /// Installed, but older than the adapter supports.
    case unsupportedVersion(CLIIdentifier, found: SemanticVersion?, minimum: SemanticVersion)
    /// The CLI reported no usable credentials. `loginCommand` is what fixes it.
    case notAuthenticated(CLIIdentifier, loginCommand: String)
    /// The adapter does not implement the requested capability at all.
    case unsupportedCapability(CLIIdentifier, CLICapabilities)
    /// The CLI cannot express this policy faithfully, and the adapter refuses to
    /// silently substitute a broader one.
    case unsupportedPermissionPolicy(CLIIdentifier, PermissionPolicy, reason: String)
    /// A flag the adapter needs is missing from the installed build.
    case unsupportedByVersion(CLIIdentifier, feature: String, found: SemanticVersion?)
    /// The requested model is not one this CLI will run.
    ///
    /// Distinct from ``unsupportedCapability(_:_:)``: model selection works, the
    /// name does not. It is usually not a typo — Copilot resolves the available
    /// set against the signed-in account at launch, so a name that worked
    /// yesterday, or that the CLI itself wrote into its own settings, can be
    /// refused today.
    case unsupportedModel(CLIIdentifier, model: String, reason: String)
    /// The CLI no longer knows about this session.
    case sessionNotFound(SessionReference)
    /// The session exists but can no longer be continued.
    case sessionExpired(SessionReference)
    /// Resume was attempted from a different directory than the session was
    /// created in, and the CLI scopes sessions by directory.
    case workingDirectoryMismatch(SessionReference, attempted: URL)
    /// The run exceeded ``RunConfiguration/timeout``. The process tree was killed.
    case timedOut(CLIIdentifier, after: Duration)
    /// The surrounding `Task` was cancelled. The process tree was killed.
    case cancelled(CLIIdentifier)
    /// The agent hit ``RunConfiguration/maximumTurns`` before finishing.
    case turnLimitReached(CLIIdentifier, partialText: String)
    /// Output exceeded ``RunConfiguration/maximumOutputBytes``.
    case outputLimitExceeded(CLIIdentifier, bytes: Int)
    /// The reply could not be decoded into the requested ``StructuredOutput``.
    /// Carries the text that failed, so the caller can log or retry with it.
    case structuredOutputFailed(reason: String, text: String)
    /// An attachment could not be read or fetched.
    case attachmentUnavailable(URL, reason: String)
    /// An attachment exceeded ``RunConfiguration/maximumAttachmentBytes``.
    case attachmentTooLarge(URL, byteCount: Int, limit: Int)
    /// Output could not be parsed into the expected shape — usually a sign the
    /// CLI changed its format.
    case malformedOutput(reason: String, raw: Data?)
    /// The process exited non-zero without a more specific mapping.
    case processFailed(CLIIdentifier, exitCode: Int32, standardError: String)
    /// The process could not be spawned at all.
    case launchFailed(CLIIdentifier, reason: String)
    /// The working directory does not exist or is not a directory.
    case invalidWorkingDirectory(URL)
}

extension AgenticCLIError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .notInstalled(cli, hint):
            return "\(cli) is not installed. Install it with: \(hint)"
        case let .unsupportedVersion(cli, found, minimum):
            let foundText = found.map(\.description) ?? "an unreadable version"
            return "\(cli) is \(foundText); \(minimum) or newer is required."
        case let .notAuthenticated(cli, command):
            return "\(cli) is not signed in. Run: \(command)"
        case let .unsupportedCapability(cli, capability):
            return "\(cli) does not support \(capability)."
        case let .unsupportedPermissionPolicy(cli, policy, reason):
            return "\(cli) cannot honour the permission policy \(policy): \(reason)"
        case let .unsupportedModel(cli, model, reason):
            return "\(cli) cannot run the model '\(model)': \(reason)"
        case let .unsupportedByVersion(cli, feature, found):
            let foundText = found.map(\.description) ?? "the installed version"
            return "\(cli) \(foundText) does not support \(feature)."
        case let .sessionNotFound(session):
            return "Session \(session.sessionID) no longer exists in \(session.cli)."
        case let .sessionExpired(session):
            return "Session \(session.sessionID) can no longer be resumed."
        case let .workingDirectoryMismatch(session, attempted):
            return """
            Session \(session.sessionID) belongs to \(session.workingDirectory.path) \
            and cannot be resumed from \(attempted.path).
            """
        case let .timedOut(cli, duration):
            return "\(cli) exceeded its \(duration.seconds)s timeout and was terminated."
        case let .cancelled(cli):
            return "The \(cli) run was cancelled."
        case let .turnLimitReached(cli, _):
            return "\(cli) reached its turn limit before finishing."
        case let .outputLimitExceeded(cli, bytes):
            return "\(cli) produced more than \(bytes) bytes of output."
        case let .structuredOutputFailed(reason, _):
            return "Structured output failed: \(reason)"
        case let .attachmentUnavailable(url, reason):
            return "Could not attach \(url.lastPathComponent): \(reason)"
        case let .attachmentTooLarge(url, byteCount, limit):
            return "\(url.lastPathComponent) is \(byteCount) bytes; the limit is \(limit)"
        case let .malformedOutput(reason, _):
            return "Could not parse CLI output: \(reason)"
        case let .processFailed(cli, exitCode, standardError):
            let detail = standardError.isEmpty ? "" : ": \(standardError.prefix(500))"
            return "\(cli) exited with code \(exitCode)\(detail)"
        case let .launchFailed(cli, reason):
            return "Could not start \(cli): \(reason)"
        case let .invalidWorkingDirectory(url):
            return "Working directory does not exist: \(url.path)"
        }
    }

    /// A suggested next step for the user, where one exists.
    public var recoverySuggestion: String? {
        switch self {
        case let .notInstalled(_, hint): return hint
        case let .notAuthenticated(_, command): return "Run `\(command)` in a terminal."
        case let .unsupportedVersion(cli, _, minimum): return "Update \(cli) to \(minimum) or newer."
        case .turnLimitReached: return "Raise RunConfiguration.maximumTurns or resume the session."
        case .timedOut: return "Raise RunConfiguration.timeout."
        case .attachmentTooLarge: return "Raise RunConfiguration.maximumAttachmentBytes or send a smaller file."
        case let .unsupportedModel(cli, _, _):
            return "Enable the model for your account, leave RunConfiguration.model unset "
                + "to use \(cli)'s own default, or pick a model it currently offers."
        default: return nil
        }
    }

    /// The CLI the failure came from, when it is attributable to one.
    public var cli: CLIIdentifier? {
        switch self {
        case let .notInstalled(cli, _), let .unsupportedVersion(cli, _, _),
             let .notAuthenticated(cli, _), let .unsupportedCapability(cli, _),
             let .unsupportedPermissionPolicy(cli, _, _), let .unsupportedByVersion(cli, _, _),
             let .unsupportedModel(cli, _, _),
             let .timedOut(cli, _), let .cancelled(cli),
             let .turnLimitReached(cli, _), let .outputLimitExceeded(cli, _),
             let .processFailed(cli, _, _), let .launchFailed(cli, _):
            return cli
        case let .sessionNotFound(session), let .sessionExpired(session),
             let .workingDirectoryMismatch(session, _):
            return session.cli
        case .malformedOutput, .invalidWorkingDirectory, .structuredOutputFailed,
             .attachmentUnavailable, .attachmentTooLarge:
            return nil
        }
    }

    /// True when retrying the same request could plausibly succeed.
    public var isTransient: Bool {
        switch self {
        case .timedOut, .cancelled, .launchFailed: return true
        default: return false
        }
    }
}
