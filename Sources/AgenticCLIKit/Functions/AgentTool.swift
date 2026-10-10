import Foundation

/// A tool the agent can call, with typed arguments and a typed result.
///
/// The shape mirrors Foundation Models' `Tool`, so a type written against
/// on-device inference ports over with one change: the argument schema is
/// written out as a ``JSONSchema`` instead of being derived from `@Generable`.
/// This package ships no macro and takes no dependencies, and a hand-written
/// schema is what the CLIs are handed anyway.
///
/// ```swift
/// struct WeatherTool: AgentTool {
///     let name = "getWeather"
///     let description = "Retrieve the latest weather information for a city"
///
///     struct Arguments: Decodable, Sendable {
///         let city: String
///     }
///
///     struct Forecast: Encodable, Sendable {
///         let city: String
///         let temperature: Int
///     }
///
///     let argumentSchema = JSONSchema.object([
///         "city": .string("The city to get weather information for"),
///     ])
///
///     func call(arguments: Arguments) async throws -> Forecast {
///         Forecast(city: arguments.city, temperature: .random(in: 30...100))
///     }
/// }
///
/// let session = AgentSession(
///     cli: .claudeCode,
///     workingDirectory: directory,
///     tools: [WeatherTool()],
///     instructions: "Help the person with getting weather information"
/// )
///
/// let response = try await session.respond(to: "Is it hotter in Boston, Wichita, or Pittsburgh?")
/// ```
///
/// Calls are resolved by ``AgentSession`` over a reply format this package
/// defines — no MCP server, no socket, nothing written to the user's CLI
/// configuration. See ``ToolCallFormat`` for the exchange itself.
///
/// `Output` reaches the model as JSON, unless it is already a `String`.
public protocol AgentTool: Sendable {
    /// Decoded from what the model produces. Use ``NoArguments`` for a tool that
    /// takes none.
    associatedtype Arguments: Decodable & Sendable
    /// Handed back to the model. A record type arrives as a record.
    associatedtype Output: Encodable & Sendable

    /// Identifier the model calls. Letters, digits, `_` and `-`; 64 characters
    /// at most.
    var name: String { get }
    /// What the tool does, in the model's terms. This is the only thing deciding
    /// whether it gets called at the right moment, so it is worth writing
    /// properly.
    var description: String { get }
    /// Schema for ``Arguments``, as the model must produce it.
    var argumentSchema: JSONSchema { get }

    func call(arguments: Arguments) async throws -> Output
}

extension AgentTool {
    /// The type-erased form a run actually carries.
    public var erased: AgentFunction { AgentFunction(self) }
}

extension AgentTool where Arguments == NoArguments {
    /// A tool that takes nothing needs no schema written for it.
    public var argumentSchema: JSONSchema { .object([:]) }
}

/// Arguments for a tool that takes none.
public struct NoArguments: Decodable, Sendable {
    public init() {}

    /// Accepts whatever the model sent, including the empty object it will
    /// usually send, and ignores it.
    public init(from decoder: any Decoder) throws {}
}

extension Array where Element == any AgentTool {
    /// The type-erased forms, in order.
    public var erased: [AgentFunction] { map(\.erased) }
}
