import Foundation

/// A model the installed CLI can be asked to use.
///
/// Where possible these come from the CLI on the machine rather than from a list
/// baked into this package — one of the three prompting CLIs can enumerate its
/// models, and asking it beats shipping a catalogue that goes stale. The other
/// two cannot, so their adapters carry a hand-maintained ``KnownModel`` list.
///
/// ``origin`` matters as much as ``id``, and says which case you are looking at:
/// a live backend catalogue, a maintained list, the user's own configured
/// default, or an alias parsed from `--help`. Surfacing the difference lets an
/// app show a real picker where it has one and a free-text field where it does
/// not.
public struct AgentModel: Sendable, Hashable, Codable, Identifiable {
    /// The value to put in ``RunConfiguration/model``.
    public let id: String
    /// Human-facing name, when the CLI provides one.
    public let displayName: String?
    /// What the CLI says the model is for, when it says anything.
    public let summary: String?
    /// Whether the CLI would use this model without being told to.
    public let isDefault: Bool
    /// How much to trust this entry, and where it came from.
    public let origin: Origin

    public init(
        id: String,
        displayName: String? = nil,
        summary: String? = nil,
        isDefault: Bool = false,
        origin: Origin
    ) {
        self.id = id
        self.displayName = displayName
        self.summary = summary
        self.isDefault = isDefault
        self.origin = origin
    }

    /// Where a model entry came from.
    public enum Origin: String, Sendable, Codable, CaseIterable {
        /// The CLI enumerated it, usually by asking its backend. Authoritative
        /// and complete: safe to render as an exhaustive picker.
        case catalog
        /// A hand-maintained list shipped with this package, for CLIs that
        /// cannot enumerate their models. Accurate when the package was
        /// released; update it when the vendor ships a model.
        case bundled
        /// Read from the user's own CLI configuration. Correct, but it is one
        /// model — the one they configured — not the set of available ones.
        case configuration
        /// Parsed from the CLI's own `--help`. Real, and it tracks the installed
        /// binary, but it is whatever the vendor chose to document — typically a
        /// few aliases, not the full list.
        case documentation
    }

    /// Best label for a picker row.
    public var label: String { displayName ?? id }

    /// Whether this entry can be treated as a complete list of choices.
    public var isAuthoritative: Bool { origin == .catalog }
}

/// A hand-maintained model list shipped alongside an adapter.
///
/// Two of the CLIs cannot enumerate their models — `claude models` is a billable
/// agent turn rather than a command, and `codex models` needs a TTY — so their
/// adapters carry a list instead. Conforming enums are the maintenance surface:
/// when a vendor ships a model, add a case.
///
/// Nothing depends on the list being complete. ``RunConfiguration/model`` is a
/// free-form `String`, so a model released after this package was tagged can be
/// used immediately by passing its identifier directly.
public protocol KnownModel: RawRepresentable, CaseIterable, Sendable, Hashable
where RawValue == String, AllCases: Sendable {
    /// The CLI this list belongs to.
    static var cli: CLIIdentifier { get }
    /// The model the CLI uses when none is requested.
    static var `default`: Self { get }
    /// Human-facing name for a picker.
    var displayName: String { get }
    /// What the model is good for, when that is worth saying.
    var summary: String? { get }
}

extension KnownModel {
    public var summary: String? { nil }

    /// The value to pass as ``RunConfiguration/model``.
    public var id: String { rawValue }

    public var agentModel: AgentModel {
        AgentModel(
            id: rawValue,
            displayName: displayName,
            summary: summary,
            isDefault: self == Self.default,
            origin: .bundled
        )
    }

    /// The whole list, as ``AgentModel`` values.
    public static var agentModels: [AgentModel] {
        allCases.map(\.agentModel)
    }
}

extension RunConfiguration {
    /// Selects a model from an adapter's hand-maintained list.
    ///
    /// ```swift
    /// configuration.use(ClaudeCode.Model.opus)
    /// ```
    ///
    /// Leaving ``model`` `nil` — the default — passes no model flag at all, so
    /// the CLI uses whatever the user configured. That is usually what a host
    /// app wants: the user's own choice, not one this library picked.
    public mutating func use(_ model: some KnownModel) {
        self.model = model.rawValue
    }

    /// A copy that runs on `model`.
    public func using(_ model: some KnownModel) -> RunConfiguration {
        var copy = self
        copy.use(model)
        return copy
    }
}

extension AgentModel: CustomStringConvertible {
    public var description: String {
        var text = label
        if displayName != nil { text += " (\(id))" }
        if isDefault { text += " [default]" }
        return text
    }
}

extension Array where Element == AgentModel {
    /// The model the CLI would use on its own, if it named one.
    public var defaultModel: AgentModel? {
        first { $0.isDefault }
    }

    /// True when every entry was enumerated by the CLI, so the list is complete.
    public var isCompleteCatalogue: Bool {
        !isEmpty && allSatisfy { $0.origin == .catalog }
    }
}

extension AgenticCLI {
    /// Models the installed CLI reports.
    ///
    /// Adapters without ``CLICapabilities/modelDiscovery`` throw
    /// ``AgenticCLIError/unsupportedCapability(_:_:)``.
    ///
    /// Discovery is a convenience, not a constraint: ``RunConfiguration/model``
    /// stays a free-form `String`, so a model released tomorrow works today
    /// without updating this package.
    public func availableModels() async throws -> [AgentModel] {
        throw AgenticCLIError.unsupportedCapability(identifier, .modelDiscovery)
    }
}

extension AgenticCLIKit {
    /// Models reported by a registered CLI.
    public func availableModels(for identifier: CLIIdentifier) async throws -> [AgentModel] {
        try await agent(for: identifier).availableModels()
    }

    /// Models for every registered CLI that can report them, probed concurrently.
    ///
    /// CLIs that cannot are omitted rather than throwing, so one adapter without
    /// discovery does not deny an app the pickers it can build for the others.
    public func availableModelsByCLI() async -> [CLIIdentifier: [AgentModel]] {
        await withTaskGroup(of: (CLIIdentifier, [AgentModel])?.self) { group in
            for agent in agents where agent.capabilities.contains(.modelDiscovery) {
                group.addTask {
                    guard let models = try? await agent.availableModels(), !models.isEmpty else {
                        return nil
                    }
                    return (agent.identifier, models)
                }
            }

            var result: [CLIIdentifier: [AgentModel]] = [:]
            for await entry in group {
                if let entry { result[entry.0] = entry.1 }
            }
            return result
        }
    }
}
