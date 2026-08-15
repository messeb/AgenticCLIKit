import Foundation

/// Everything about a run except the prompt itself.
///
/// ``permissions`` and ``workingDirectory`` have no defaults — both are
/// decisions the host app must make consciously.
public struct RunConfiguration: Sendable {
    /// Directory the agent treats as its workspace root.
    public var workingDirectory: URL
    /// What the agent may do. See ``PermissionPolicy``.
    public var permissions: PermissionPolicy
    /// Model name or alias, passed through untranslated. Requires
    /// ``CLICapabilities/modelSelection``.
    public var model: String?
    /// Wall-clock budget for the whole run. The child process and its
    /// descendants are terminated when it elapses.
    public var timeout: Duration
    /// Cap on agent turns. Requires ``CLICapabilities/turnLimits``.
    public var maximumTurns: Int?
    /// When `false`, ask the CLI not to persist a resumable session.
    /// Requires ``CLICapabilities/ephemeralRuns``.
    public var persistsSession: Bool
    /// Extra directories the agent may access, beyond ``workingDirectory``.
    /// Requires ``CLICapabilities/additionalDirectories``.
    public var additionalDirectories: [URL]
    /// Text appended to the CLI's own system prompt, where supported.
    public var systemPromptAppendix: String?
    /// Which environment variables reach the child. Adapters extend this with
    /// their own credential keys.
    public var environmentPolicy: EnvironmentPolicy
    /// Values layered on top of ``environmentPolicy``, applied last.
    public var environmentOverrides: [String: String]
    /// Data piped to the child's stdin. `nil` closes stdin immediately, which
    /// is what keeps prompt-waiting CLIs from hanging forever.
    public var standardInput: Data?
    /// Hard cap on buffered stdout, to bound memory on a runaway agent.
    public var maximumOutputBytes: Int
    /// Schema the CLI should enforce on its final message. Usually set for you
    /// by ``AgenticCLI/run(_:returning:configuration:)``; set it directly when
    /// you want a schema without a Swift type to decode into.
    /// Requires ``CLICapabilities/nativeOutputSchema``.
    public var outputSchema: JSONSchema?
    /// Files, data, and URLs to put in front of the agent. Remote URLs are
    /// downloaded by the kit before the run. Requires
    /// ``CLICapabilities/fileAttachments``.
    public var attachments: [PromptAttachment]
    /// Ceiling on any single attachment, after download.
    public var maximumAttachmentBytes: Int
    /// Arguments appended verbatim, after everything the adapter generates.
    /// The escape hatch for flags the kit does not model yet.
    public var extraArguments: [String]

    public init(
        workingDirectory: URL,
        permissions: PermissionPolicy,
        model: String? = nil,
        timeout: Duration = .seconds(300),
        maximumTurns: Int? = nil,
        persistsSession: Bool = true,
        additionalDirectories: [URL] = [],
        systemPromptAppendix: String? = nil,
        environmentPolicy: EnvironmentPolicy = .base,
        environmentOverrides: [String: String] = [:],
        standardInput: Data? = nil,
        maximumOutputBytes: Int = 32 * 1024 * 1024,
        outputSchema: JSONSchema? = nil,
        attachments: [PromptAttachment] = [],
        maximumAttachmentBytes: Int = 32 * 1024 * 1024,
        extraArguments: [String] = []
    ) {
        self.workingDirectory = workingDirectory
        self.permissions = permissions
        self.model = model
        self.timeout = timeout
        self.maximumTurns = maximumTurns
        self.persistsSession = persistsSession
        self.additionalDirectories = additionalDirectories
        self.systemPromptAppendix = systemPromptAppendix
        self.environmentPolicy = environmentPolicy
        self.environmentOverrides = environmentOverrides
        self.standardInput = standardInput
        self.maximumOutputBytes = maximumOutputBytes
        self.outputSchema = outputSchema
        self.attachments = attachments
        self.maximumAttachmentBytes = maximumAttachmentBytes
        self.extraArguments = extraArguments
    }

    /// A read-only run rooted at `directory`.
    public static func readOnly(in directory: URL, timeout: Duration = .seconds(300)) -> RunConfiguration {
        RunConfiguration(workingDirectory: directory, permissions: .readOnly, timeout: timeout)
    }

    /// A plan-only run rooted at `directory`.
    public static func planOnly(in directory: URL, timeout: Duration = .seconds(300)) -> RunConfiguration {
        RunConfiguration(workingDirectory: directory, permissions: .planOnly, timeout: timeout)
    }
}
