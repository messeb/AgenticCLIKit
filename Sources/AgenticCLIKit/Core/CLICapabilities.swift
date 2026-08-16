import Foundation

/// What an adapter's underlying CLI can actually do.
///
/// Callers should branch on capabilities rather than on ``CLIIdentifier``, so
/// that new adapters slot in without changing call sites. Adapters throw
/// ``AgenticCLIError/unsupportedCapability(_:_:)`` when asked for something
/// outside their declared set.
public struct CLICapabilities: OptionSet, Hashable, Sendable, Codable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Accepts a free-form prompt and produces an agent response.
    /// Not every CLI does.
    public static let prompting = CLICapabilities(rawValue: 1 << 0)
    /// Creates resumable sessions and can continue them from a later process.
    public static let sessions = CLICapabilities(rawValue: 1 << 1)
    /// Emits incremental events while a turn is in flight.
    public static let streaming = CLICapabilities(rawValue: 1 << 2)
    /// Emits machine-readable output (JSON or JSONL) rather than prose.
    public static let structuredOutput = CLICapabilities(rawValue: 1 << 3)
    /// Honours ``RunConfiguration/model``.
    public static let modelSelection = CLICapabilities(rawValue: 1 << 4)
    /// Honours ``RunConfiguration/maximumTurns``.
    public static let turnLimits = CLICapabilities(rawValue: 1 << 5)
    /// Reports token counts, and possibly cost, for a completed turn.
    public static let usageReporting = CLICapabilities(rawValue: 1 << 6)
    /// Accepts a per-tool allowlist (``PermissionPolicy/allowingTools(allowed:denied:)``).
    public static let toolAllowlist = CLICapabilities(rawValue: 1 << 7)
    /// A session started in one directory can be resumed from another.
    public static let resumeAcrossDirectories = CLICapabilities(rawValue: 1 << 8)
    /// Can run a turn without writing a session to disk.
    public static let ephemeralRuns = CLICapabilities(rawValue: 1 << 9)
    /// Accepts additional writable/readable directories beyond the working directory.
    public static let additionalDirectories = CLICapabilities(rawValue: 1 << 10)
    /// Honours ``RunConfiguration/systemPromptAppendix``.
    public static let systemPromptCustomization = CLICapabilities(rawValue: 1 << 12)
    /// Enforces a JSON Schema on the final message, so ``StructuredOutput``
    /// decoding checks a contract the provider already applied.
    public static let nativeOutputSchema = CLICapabilities(rawValue: 1 << 13)
    /// Can read files given to it by path (``RunConfiguration/attachments``).
    public static let fileAttachments = CLICapabilities(rawValue: 1 << 14)
    /// Has a dedicated flag for attaching images, rather than relying on the
    /// agent opening them from disk.
    public static let nativeImageAttachments = CLICapabilities(rawValue: 1 << 15)
    /// Can report the models it accepts — from its own catalogue, its
    /// configuration, or a list this package maintains. See ``AgentModel/Origin``.
    public static let modelDiscovery = CLICapabilities(rawValue: 1 << 16)
    /// The adapter tracks a young or fast-moving CLI; expect breakage.
    public static let experimental = CLICapabilities(rawValue: 1 << 11)
}

extension CLICapabilities: CustomStringConvertible {
    private static let names: [(CLICapabilities, String)] = [
        (.prompting, "prompting"),
        (.sessions, "sessions"),
        (.streaming, "streaming"),
        (.structuredOutput, "structuredOutput"),
        (.modelSelection, "modelSelection"),
        (.turnLimits, "turnLimits"),
        (.usageReporting, "usageReporting"),
        (.toolAllowlist, "toolAllowlist"),
        (.resumeAcrossDirectories, "resumeAcrossDirectories"),
        (.ephemeralRuns, "ephemeralRuns"),
        (.additionalDirectories, "additionalDirectories"),
        (.systemPromptCustomization, "systemPromptCustomization"),
        (.nativeOutputSchema, "nativeOutputSchema"),
        (.fileAttachments, "fileAttachments"),
        (.nativeImageAttachments, "nativeImageAttachments"),
        (.modelDiscovery, "modelDiscovery"),
        (.experimental, "experimental"),
    ]

    public var description: String {
        let present = Self.names.filter { contains($0.0) }.map(\.1)
        return present.isEmpty ? "[]" : "[\(present.joined(separator: ", "))]"
    }
}
