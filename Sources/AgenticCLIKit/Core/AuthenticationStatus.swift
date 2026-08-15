import Foundation

/// How a CLI's credentials were supplied.
///
/// The distinction matters: an environment API key bypasses stored profiles and
/// often does not show up as "logged in" to the CLI's own status command.
public enum AuthenticationMethod: String, Hashable, Sendable, Codable {
    /// Interactive OAuth against the vendor's account system.
    case oauth
    /// A subscription account (Claude Max, ChatGPT Plus, …) linked by OAuth.
    case subscription
    /// An API key read from the process environment.
    case environmentKey
    /// A long-lived token created for headless use (`claude setup-token`).
    case longLivedToken
    /// Credentials held in the system keychain by the CLI itself.
    case keychain
    /// A third-party gateway (Bedrock, Vertex, enterprise proxy).
    case thirdPartyProvider
    case unknown
}

/// The account behind a set of credentials, as far as the CLI will disclose it.
public struct AuthenticatedAccount: Hashable, Sendable, Codable {
    /// Email, login handle, or whatever the CLI prints. `nil` when it prints nothing.
    public let identifier: String?
    public let method: AuthenticationMethod
    public let organization: String?
    /// Plan or subscription tier, e.g. `"max"`.
    public let plan: String?
    /// Credential expiry when the CLI reports one.
    public let expiresAt: Date?
    /// The environment variable that supplied the credential, for `.environmentKey`.
    public let environmentVariable: String?

    public init(
        identifier: String? = nil,
        method: AuthenticationMethod,
        organization: String? = nil,
        plan: String? = nil,
        expiresAt: Date? = nil,
        environmentVariable: String? = nil
    ) {
        self.identifier = identifier
        self.method = method
        self.organization = organization
        self.plan = plan
        self.expiresAt = expiresAt
        self.environmentVariable = environmentVariable
    }
}

/// Whether a CLI is ready to do work, established without side effects.
///
/// Probes are non-interactive by contract: they never open a browser, never
/// write credentials, and always run under a hard timeout.
public enum AuthenticationStatus: Hashable, Sendable, Codable {
    case authenticated(AuthenticatedAccount)
    /// Credentials exist but have lapsed. `loginCommand` re-establishes them.
    case expired(AuthenticatedAccount?, loginCommand: String)
    case requiresLogin(loginCommand: String)
    /// The CLI offers no safe way to ask. Treat as "probably usable, will find out".
    case undetectable(reason: String)
    /// The probe itself failed (timed out, crashed, unparseable output).
    case probeFailed(reason: String)

    /// True only for ``authenticated(_:)``. ``undetectable(reason:)`` is
    /// deliberately not ready-by-default; use ``isBlocked`` to decide whether to
    /// show a "Sign in" affordance.
    public var isAuthenticated: Bool {
        if case .authenticated = self { return true }
        return false
    }

    /// True when the user must act before runs can succeed.
    public var isBlocked: Bool {
        switch self {
        case .requiresLogin, .expired: return true
        case .authenticated, .undetectable, .probeFailed: return false
        }
    }

    /// The command that would fix a blocked state, for hand-off to the host app.
    public var loginCommand: String? {
        switch self {
        case let .requiresLogin(command): return command
        case let .expired(_, command): return command
        case .authenticated, .undetectable, .probeFailed: return nil
        }
    }

    public var account: AuthenticatedAccount? {
        switch self {
        case let .authenticated(account): return account
        case let .expired(account, _): return account
        case .requiresLogin, .undetectable, .probeFailed: return nil
        }
    }
}

extension AuthenticationStatus: CustomStringConvertible {
    public var description: String {
        switch self {
        case let .authenticated(account):
            let who = account.identifier ?? "authenticated"
            return "\(who) via \(account.method.rawValue)"
        case let .expired(_, command):
            return "expired — run `\(command)`"
        case let .requiresLogin(command):
            return "not logged in — run `\(command)`"
        case let .undetectable(reason):
            return "unknown (\(reason))"
        case let .probeFailed(reason):
            return "probe failed (\(reason))"
        }
    }
}
