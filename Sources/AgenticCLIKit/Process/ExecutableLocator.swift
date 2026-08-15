import Foundation

/// Resolves a CLI's name to an absolute path.
public protocol ExecutableLocating: Sendable {
    func locate(_ executableName: String) async -> URL?
}

/// Finds executables the way a terminal would, not the way a GUI app does.
///
/// This is the single most common integration bug in this space. A macOS app
/// launched from Finder inherits a `PATH` of roughly `/usr/bin:/bin:/usr/sbin:/sbin`
/// — no Homebrew, no `~/.local/bin`, no nvm. The CLI the user definitely has
/// installed is simply invisible. So the locator asks the user's *login shell*
/// what it would resolve, and caches the answer.
public actor LoginShellExecutableLocator: ExecutableLocating {
    /// Paths checked before consulting the shell, in order. Populated with the
    /// usual suspects so the common case avoids spawning a shell at all.
    public static let wellKnownDirectories: [String] = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "~/.local/bin",
        "~/.bun/bin",
        "~/.deno/bin",
        "~/.cargo/bin",
        "~/go/bin",
        "~/.npm-global/bin",
        "~/.volta/bin",
        "~/.claude/local",
        "~/.codex/bin",
        "/opt/local/bin",
    ]

    private var cache: [String: URL?] = [:]
    private let hostEnvironment: [String: String]
    private let fileManager: FileManager
    private let shellTimeout: Duration
    /// Explicit overrides, e.g. from an app preference "path to claude".
    private let overrides: [String: URL]

    public init(
        hostEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        overrides: [String: URL] = [:],
        shellTimeout: Duration = .seconds(5),
        fileManager: FileManager = .default
    ) {
        self.hostEnvironment = hostEnvironment
        self.overrides = overrides
        self.shellTimeout = shellTimeout
        self.fileManager = fileManager
    }

    public func locate(_ executableName: String) async -> URL? {
        if let cached = cache[executableName] { return cached }
        let resolved = await resolve(executableName)
        cache[executableName] = resolved
        return resolved
    }

    /// Drops cached resolutions, for use after the user installs a CLI without
    /// restarting the app.
    public func invalidate(_ executableName: String? = nil) {
        if let executableName {
            cache.removeValue(forKey: executableName)
        } else {
            cache.removeAll()
        }
    }

    private func resolve(_ executableName: String) async -> URL? {
        if let override = overrides[executableName] {
            return isExecutable(override) ? override : nil
        }
        if executableName.contains("/") {
            let url = URL(fileURLWithPath: (executableName as NSString).expandingTildeInPath)
            return isExecutable(url) ? url : nil
        }
        if let fromPath = searchPath(for: executableName) {
            return fromPath
        }
        if let fromWellKnown = searchWellKnownDirectories(for: executableName) {
            return fromWellKnown
        }
        return await searchLoginShell(for: executableName)
    }

    private func searchPath(for executableName: String) -> URL? {
        guard let path = hostEnvironment["PATH"] else { return nil }
        for directory in path.split(separator: ":") where !directory.isEmpty {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(executableName)
            if isExecutable(candidate) { return candidate }
        }
        return nil
    }

    private func searchWellKnownDirectories(for executableName: String) -> URL? {
        for directory in Self.wellKnownDirectories {
            let expanded = (directory as NSString).expandingTildeInPath
            let candidate = URL(fileURLWithPath: expanded).appendingPathComponent(executableName)
            if isExecutable(candidate) { return candidate }
        }
        return nil
    }

    /// Last resort: ask the login shell. Costs ~100ms because it sources the
    /// user's profile, which is exactly why it runs last and gets cached.
    private func searchLoginShell(for executableName: String) async -> URL? {
        let shell = hostEnvironment["SHELL"].map(URL.init(fileURLWithPath:))
            ?? URL(fileURLWithPath: "/bin/zsh")
        guard isExecutable(shell) else { return nil }

        let invocation = ProcessInvocation(
            executableURL: shell,
            // `command -v` is POSIX and, unlike `which`, is a shell builtin that
            // respects the profile's PATH exactly.
            arguments: ["-lc", "command -v -- \(shellQuoted(executableName))"],
            environment: EnvironmentPolicy.base.resolved(againstHostEnvironment: hostEnvironment),
            timeout: shellTimeout,
            maximumOutputBytes: 64 * 1024
        )

        guard
            let result = try? await SubprocessRunner().run(invocation),
            result.exit.isSuccess
        else { return nil }

        let path = result.standardOutputText
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && $0.hasPrefix("/") }

        guard let path else { return nil }
        let url = URL(fileURLWithPath: path)
        return isExecutable(url) ? url : nil
    }

    private func isExecutable(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return false
        }
        return fileManager.isExecutableFile(atPath: url.path)
    }

    private func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}

/// A locator with fixed answers, for tests and for apps that let the user pick
/// paths explicitly.
public struct StaticExecutableLocator: ExecutableLocating {
    private let paths: [String: URL]

    public init(_ paths: [String: URL]) {
        self.paths = paths
    }

    public func locate(_ executableName: String) async -> URL? {
        paths[executableName]
    }
}
