import Foundation
#if canImport(os)
import os
#endif

/// Structured logging with a redaction rule: prompts, output text, and anything
/// credential-shaped never reach the log by default.
///
/// A log line that leaks a user's prompt into the unified system log is a
/// privacy incident, not a debugging convenience. Turn on
/// ``Log/isPromptLoggingEnabled`` only in your own debug builds.
public enum Log {
    /// When `true`, prompt and response text is logged in full. Off by default.
    public static var isPromptLoggingEnabled: Bool {
        get { promptLoggingFlag.withLock { $0 } }
        set { promptLoggingFlag.withLock { $0 = newValue } }
    }

    private static let promptLoggingFlag = Mutex(false)

    #if canImport(os)
    static let discovery = Logger(subsystem: subsystem, category: "discovery")
    static let authentication = Logger(subsystem: subsystem, category: "authentication")
    static let execution = Logger(subsystem: subsystem, category: "execution")
    static let session = Logger(subsystem: subsystem, category: "session")

    private static let subsystem = "com.agenticclikit"
    #endif

    /// Redacts text unless prompt logging was explicitly enabled.
    static func redacted(_ text: String) -> String {
        isPromptLoggingEnabled ? text : "<redacted \(text.count) chars>"
    }

    static func debug(_ category: Category, _ message: @autoclosure () -> String) {
        #if canImport(os)
        let text = message()
        logger(for: category).debug("\(text, privacy: .public)")
        #endif
    }

    static func info(_ category: Category, _ message: @autoclosure () -> String) {
        #if canImport(os)
        let text = message()
        logger(for: category).info("\(text, privacy: .public)")
        #endif
    }

    static func warning(_ category: Category, _ message: @autoclosure () -> String) {
        #if canImport(os)
        let text = message()
        logger(for: category).warning("\(text, privacy: .public)")
        #endif
    }

    /// For ``PermissionPolicy/unsafeBypassAll`` and other decisions that deserve
    /// to be findable after the fact.
    static func fault(_ category: Category, _ message: @autoclosure () -> String) {
        #if canImport(os)
        let text = message()
        logger(for: category).fault("\(text, privacy: .public)")
        #endif
    }

    enum Category {
        case discovery, authentication, execution, session
    }

    #if canImport(os)
    private static func logger(for category: Category) -> Logger {
        switch category {
        case .discovery: return discovery
        case .authentication: return authentication
        case .execution: return execution
        case .session: return session
        }
    }
    #endif
}

/// Minimal mutex, so the package keeps its zero-dependency promise on the
/// deployment targets it supports (`Synchronization.Mutex` is macOS 15+).
final class Mutex<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) {
        self.value = value
    }

    func withLock<T>(_ body: (inout Value) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}
