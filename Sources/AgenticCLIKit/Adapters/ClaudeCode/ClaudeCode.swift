import Foundation

/// Namespace for the Claude Code (`claude`) adapter and its payload types.
///
/// Verified against `claude` 2.1.224.
public enum ClaudeCode {
    /// Tools that cannot modify the workspace, used for
    /// ``PermissionPolicy/readOnly``.
    ///
    /// Claude Code denies anything outside the allowlist automatically in print
    /// mode — there is no interactive prompt to hang on.
    public static let readOnlyTools = ["Read", "Glob", "Grep", "WebFetch", "WebSearch", "TodoWrite"]

    /// Tools explicitly denied under ``PermissionPolicy/readOnly``, as a second
    /// line of defence if the allowlist semantics ever loosen.
    public static let mutatingTools = ["Bash", "Edit", "Write", "MultiEdit", "NotebookEdit"]
}

// MARK: - Result payload

extension ClaudeCode {
    /// The `type: "result"` object, emitted by both `--output-format json` and
    /// as the last line of `--output-format stream-json`.
    public struct ResultPayload: Decodable, Sendable {
        public let sessionID: String?
        public let result: String?
        public let isError: Bool
        public let subtype: String?
        public let stopReason: String?
        public let numTurns: Int?
        public let totalCostUSD: Double?
        public let durationMS: Int?
        public let usage: TokenUsage?
        public let modelUsage: [String: ModelUsage]?
        public let errorMessage: String?
        /// Populated when the run used `--json-schema`. `claude` reports the
        /// validated object here *and* as a JSON string in `result`; this field
        /// is the one to trust.
        public let structuredOutput: Data?

        private enum CodingKeys: String, CodingKey {
            case sessionID = "session_id"
            case result
            case isError = "is_error"
            case subtype
            case stopReason = "stop_reason"
            case numTurns = "num_turns"
            case totalCostUSD = "total_cost_usd"
            case durationMS = "duration_ms"
            case usage
            case modelUsage
            case errorMessage = "error"
            case structuredOutput = "structured_output"
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
            result = try container.decodeIfPresent(String.self, forKey: .result)
            isError = try container.decodeIfPresent(Bool.self, forKey: .isError) ?? false
            subtype = try container.decodeIfPresent(String.self, forKey: .subtype)
            stopReason = try container.decodeIfPresent(String.self, forKey: .stopReason)
            numTurns = try container.decodeIfPresent(Int.self, forKey: .numTurns)
            totalCostUSD = try container.decodeIfPresent(Double.self, forKey: .totalCostUSD)
            durationMS = try container.decodeIfPresent(Int.self, forKey: .durationMS)
            usage = try container.decodeIfPresent(TokenUsage.self, forKey: .usage)
            modelUsage = try container.decodeIfPresent([String: ModelUsage].self, forKey: .modelUsage)
            errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
            structuredOutput = try container.decodeIfPresent(JSONPassthrough.self, forKey: .structuredOutput)?.data
        }

        public struct TokenUsage: Decodable, Sendable {
            public let inputTokens: Int?
            public let outputTokens: Int?
            public let cacheReadInputTokens: Int?
            public let cacheCreationInputTokens: Int?

            private enum CodingKeys: String, CodingKey {
                case inputTokens = "input_tokens"
                case outputTokens = "output_tokens"
                case cacheReadInputTokens = "cache_read_input_tokens"
                case cacheCreationInputTokens = "cache_creation_input_tokens"
            }
        }

        public struct ModelUsage: Decodable, Sendable {
            public let inputTokens: Int?
            public let outputTokens: Int?
            public let costUSD: Double?
        }

        /// The model that did the work, when exactly one was used.
        var primaryModel: String? {
            guard let modelUsage, modelUsage.count == 1 else { return modelUsage?.keys.sorted().first }
            return modelUsage.keys.first
        }

        func makeUsageInfo() -> UsageInfo? {
            guard usage != nil || totalCostUSD != nil || numTurns != nil else { return nil }
            return UsageInfo(
                inputTokens: usage?.inputTokens,
                outputTokens: usage?.outputTokens,
                cachedInputTokens: usage?.cacheReadInputTokens,
                cacheWriteTokens: usage?.cacheCreationInputTokens,
                costUSD: totalCostUSD,
                turns: numTurns,
                model: primaryModel,
                duration: durationMS.map { .milliseconds($0) }
            )
        }
    }
}

// MARK: - Auth payload

extension ClaudeCode {
    /// Output of `claude auth status`, which prints JSON by default.
    public struct AuthPayload: Decodable, Sendable {
        public let loggedIn: Bool
        public let authMethod: String?
        public let apiProvider: String?
        public let email: String?
        public let orgName: String?
        public let subscriptionType: String?
        public let expiresAt: Date?

        private enum CodingKeys: String, CodingKey {
            case loggedIn, authMethod, apiProvider, email, orgName, subscriptionType, expiresAt
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            loggedIn = try container.decodeIfPresent(Bool.self, forKey: .loggedIn) ?? false
            authMethod = try container.decodeIfPresent(String.self, forKey: .authMethod)
            apiProvider = try container.decodeIfPresent(String.self, forKey: .apiProvider)
            email = try container.decodeIfPresent(String.self, forKey: .email)
            orgName = try container.decodeIfPresent(String.self, forKey: .orgName)
            subscriptionType = try container.decodeIfPresent(String.self, forKey: .subscriptionType)
            // Tolerate both epoch seconds and ISO-8601, since this field is rare
            // enough that its format is not load-bearing anywhere.
            if let seconds = try? container.decode(Double.self, forKey: .expiresAt) {
                expiresAt = Date(timeIntervalSince1970: seconds)
            } else if let text = try? container.decode(String.self, forKey: .expiresAt) {
                expiresAt = ISO8601DateFormatter().date(from: text)
            } else {
                expiresAt = nil
            }
        }

        var method: AuthenticationMethod {
            switch (authMethod ?? "").lowercased() {
            case let value where value.contains("claude.ai"): return .subscription
            case let value where value.contains("apikey") || value.contains("api_key"): return .environmentKey
            case let value where value.contains("token"): return .longLivedToken
            case let value where value.contains("bedrock") || value.contains("vertex") || value.contains("foundry"):
                return .thirdPartyProvider
            default:
                return (apiProvider ?? "").lowercased() == "firstparty" ? .oauth : .unknown
            }
        }
    }
}
