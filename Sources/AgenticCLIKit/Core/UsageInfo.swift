import Foundation

/// Token and cost accounting for a turn, normalised across CLIs.
///
/// Every field is optional because coverage differs: Claude Code reports cost in
/// USD, Codex and Antigravity report tokens only, `gh` reports nothing. Raw
/// vendor payloads remain available on ``AgentResponse/rawOutput``.
public struct UsageInfo: Hashable, Sendable, Codable {
    public var inputTokens: Int?
    public var outputTokens: Int?
    /// Tokens served from the provider's prompt cache.
    public var cachedInputTokens: Int?
    /// Tokens written into the provider's prompt cache.
    public var cacheWriteTokens: Int?
    /// Reasoning/thinking tokens, where reported separately.
    public var reasoningTokens: Int?
    /// Cost in USD, only when the CLI computes it.
    public var costUSD: Double?
    public var turns: Int?
    public var model: String?
    /// Wall-clock duration the CLI itself reported, which may exclude startup.
    public var duration: Duration?

    public init(
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        cachedInputTokens: Int? = nil,
        cacheWriteTokens: Int? = nil,
        reasoningTokens: Int? = nil,
        costUSD: Double? = nil,
        turns: Int? = nil,
        model: String? = nil,
        duration: Duration? = nil
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedInputTokens = cachedInputTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.reasoningTokens = reasoningTokens
        self.costUSD = costUSD
        self.turns = turns
        self.model = model
        self.duration = duration
    }

    /// Total tokens billed as input plus output, ignoring cache breakdowns.
    public var totalTokens: Int? {
        guard inputTokens != nil || outputTokens != nil else { return nil }
        return (inputTokens ?? 0) + (outputTokens ?? 0)
    }

    private enum CodingKeys: String, CodingKey {
        case inputTokens, outputTokens, cachedInputTokens, cacheWriteTokens
        case reasoningTokens, costUSD, turns, model, durationSeconds
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        inputTokens = try container.decodeIfPresent(Int.self, forKey: .inputTokens)
        outputTokens = try container.decodeIfPresent(Int.self, forKey: .outputTokens)
        cachedInputTokens = try container.decodeIfPresent(Int.self, forKey: .cachedInputTokens)
        cacheWriteTokens = try container.decodeIfPresent(Int.self, forKey: .cacheWriteTokens)
        reasoningTokens = try container.decodeIfPresent(Int.self, forKey: .reasoningTokens)
        costUSD = try container.decodeIfPresent(Double.self, forKey: .costUSD)
        turns = try container.decodeIfPresent(Int.self, forKey: .turns)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        duration = try container.decodeIfPresent(Double.self, forKey: .durationSeconds).map(Duration.seconds)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(inputTokens, forKey: .inputTokens)
        try container.encodeIfPresent(outputTokens, forKey: .outputTokens)
        try container.encodeIfPresent(cachedInputTokens, forKey: .cachedInputTokens)
        try container.encodeIfPresent(cacheWriteTokens, forKey: .cacheWriteTokens)
        try container.encodeIfPresent(reasoningTokens, forKey: .reasoningTokens)
        try container.encodeIfPresent(costUSD, forKey: .costUSD)
        try container.encodeIfPresent(turns, forKey: .turns)
        try container.encodeIfPresent(model, forKey: .model)
        try container.encodeIfPresent(duration.map(\.seconds), forKey: .durationSeconds)
    }
}

extension Duration {
    /// The duration as fractional seconds.
    var seconds: Double {
        let components = self.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
