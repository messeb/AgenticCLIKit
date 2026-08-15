import Foundation

/// What the agent is allowed to do during a run.
///
/// There is no default. Every ``RunConfiguration`` states a policy explicitly,
/// because the failure mode of a silent default here is an agent editing a
/// user's files without being asked.
///
/// Not every CLI can honour every policy. An adapter that cannot express a
/// policy faithfully throws ``AgenticCLIError/unsupportedPermissionPolicy(_:_:reason:)``
/// rather than quietly substituting a broader one. ``planOnly``, ``readOnly``,
/// and ``acceptingEdits`` are supported by every prompting adapter.
public enum PermissionPolicy: Hashable, Sendable, Codable {
    /// Produce a plan; take no action. The safest useful mode.
    case planOnly
    /// Read and search freely; no writes, no shell side effects.
    case readOnly
    /// Allow exactly the named tools, deny everything else.
    /// Requires ``CLICapabilities/toolAllowlist``.
    case allowingTools(allowed: [String], denied: [String] = [])
    /// Allow file edits in the working directory without prompting.
    case acceptingEdits
    /// Skip every permission check, including shell execution and network access.
    ///
    /// The name carries the warning, in the manner of `unsafeBitCast`. Adapters
    /// log at `.fault` when this is used.
    case unsafeBypassAll

    /// True for policies that cannot modify the user's files.
    public var isReadOnly: Bool {
        switch self {
        case .planOnly, .readOnly: return true
        case .allowingTools, .acceptingEdits, .unsafeBypassAll: return false
        }
    }

    /// Convenience for the common allowlist case.
    public static func allowingTools(_ allowed: [String]) -> PermissionPolicy {
        .allowingTools(allowed: allowed, denied: [])
    }
}

extension PermissionPolicy: CustomStringConvertible {
    public var description: String {
        switch self {
        case .planOnly: return "planOnly"
        case .readOnly: return "readOnly"
        case let .allowingTools(allowed, denied):
            let deniedText = denied.isEmpty ? "" : ", denying \(denied.joined(separator: ","))"
            return "allowingTools(\(allowed.joined(separator: ","))\(deniedText))"
        case .acceptingEdits: return "acceptingEdits"
        case .unsafeBypassAll: return "unsafeBypassAll"
        }
    }
}
