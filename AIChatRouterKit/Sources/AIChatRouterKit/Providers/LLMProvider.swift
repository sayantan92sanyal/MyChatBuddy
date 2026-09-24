import Foundation

public struct ProviderModelDescriptor: Codable, Sendable, Identifiable, Hashable {
    public let id: String
    public let providerID: ProviderID
    public let tier: ModelTier
    public let displayName: String

    public init(id: String, providerID: ProviderID, tier: ModelTier, displayName: String) {
        self.id = id
        self.providerID = providerID
        self.tier = tier
        self.displayName = displayName
    }
}

public struct ChatTurn: Sendable, Codable, Equatable {
    public enum Role: String, Codable, Sendable {
        case system
        case user
        case assistant
    }

    public let role: Role
    public let content: String

    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }
}

public struct TokenUsage: Sendable, Codable, Equatable {
    public let inputTokens: Int
    public let outputTokens: Int

    public init(inputTokens: Int, outputTokens: Int) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

public struct ProviderStreamChunk: Sendable {
    public let deltaText: String
    public let isFinal: Bool
    public let usage: TokenUsage?
    public let latencyMS: Int?

    public init(deltaText: String, isFinal: Bool = false, usage: TokenUsage? = nil, latencyMS: Int? = nil) {
        self.deltaText = deltaText
        self.isFinal = isFinal
        self.usage = usage
        self.latencyMS = latencyMS
    }
}

public enum ProviderError: Error, Sendable, Equatable {
    case missingAPIKey
    case invalidAPIKey
    case network(String)
    case rateLimited
    case decodingFailed(String)
    case cancelled
    case modelNotReady
}

/// Uniform interface for local (MLX) and cloud (Anthropic/OpenAI) completions.
/// The router and chat UI depend only on this protocol — never on a concrete provider.
public protocol LLMProvider: Sendable {
    var id: ProviderID { get }
    func isConfigured() async -> Bool
    func streamCompletion(
        model: ProviderModelDescriptor,
        systemPrompt: String?,
        turns: [ChatTurn],
        maxOutputTokens: Int
    ) -> AsyncThrowingStream<ProviderStreamChunk, Error>
}
