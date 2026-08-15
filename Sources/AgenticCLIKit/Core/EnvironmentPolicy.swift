import Foundation

/// Which environment variables reach the child process.
///
/// The kit never hands a child `ProcessInfo.processInfo.environment` wholesale.
/// A host app's environment routinely contains unrelated secrets, and an agent
/// with shell access can read all of them.
public struct EnvironmentPolicy: Hashable, Sendable {
    /// Variables inherited from the host process when present.
    public var inheritedKeys: Set<String>
    /// Variables set explicitly, overriding anything inherited.
    public var overrides: [String: String]

    public init(inheritedKeys: Set<String>, overrides: [String: String] = [:]) {
        self.inheritedKeys = inheritedKeys
        self.overrides = overrides
    }

    /// The variables every child needs: a working shell environment, locale,
    /// temp directory, and proxy/TLS settings. Deliberately excludes anything
    /// credential-shaped; adapters add their own credential keys.
    public static let base = EnvironmentPolicy(
        inheritedKeys: [
            "HOME", "USER", "LOGNAME", "PATH", "SHELL", "TMPDIR",
            "LANG", "LC_ALL", "LC_CTYPE",
            "SSL_CERT_FILE", "SSL_CERT_DIR", "NODE_EXTRA_CA_CERTS",
            "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY",
            "http_proxy", "https_proxy", "no_proxy",
            "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME",
        ],
        overrides: [
            // Force non-interactive behaviour: no pagers, no ANSI, no TTY assumptions.
            "TERM": "dumb",
            "NO_COLOR": "1",
            "PAGER": "cat",
            "GIT_PAGER": "cat",
            "CLICOLOR": "0",
        ]
    )

    /// A policy that also inherits the named credential variables.
    public func inheriting(_ keys: String...) -> EnvironmentPolicy {
        inheriting(keys)
    }

    public func inheriting(_ keys: [String]) -> EnvironmentPolicy {
        EnvironmentPolicy(inheritedKeys: inheritedKeys.union(keys), overrides: overrides)
    }

    /// A policy with additional explicit values.
    public func setting(_ values: [String: String]) -> EnvironmentPolicy {
        EnvironmentPolicy(inheritedKeys: inheritedKeys, overrides: overrides.merging(values) { _, new in new })
    }

    /// Resolves the policy against a host environment.
    ///
    /// - Parameters:
    ///   - hostEnvironment: usually `ProcessInfo.processInfo.environment`.
    ///   - additionalOverrides: caller-supplied values, applied last.
    public func resolved(
        againstHostEnvironment hostEnvironment: [String: String],
        additionalOverrides: [String: String] = [:]
    ) -> [String: String] {
        var environment: [String: String] = [:]
        for key in inheritedKeys {
            if let value = hostEnvironment[key] {
                environment[key] = value
            }
        }
        environment.merge(overrides) { _, new in new }
        environment.merge(additionalOverrides) { _, new in new }
        return environment
    }

    /// Credential variables the host environment currently defines, out of the
    /// ones this policy would pass through. Used by auth probes to report
    /// ``AuthenticationMethod/environmentKey``.
    public func presentKeys(
        among candidates: [String],
        in hostEnvironment: [String: String]
    ) -> [String] {
        candidates.filter { key in
            inheritedKeys.contains(key)
                && (hostEnvironment[key]?.isEmpty == false)
        }
    }
}
