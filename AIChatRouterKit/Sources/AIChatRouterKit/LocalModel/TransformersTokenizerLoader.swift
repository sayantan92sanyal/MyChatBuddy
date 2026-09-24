import Foundation
import MLXLMCommon
import Tokenizers

/// Bridges swift-transformers' `Tokenizer` (loaded via `AutoTokenizer.from(modelFolder:)`)
/// into mlx-swift-lm's own `Tokenizer` protocol. The two protocols are structurally close
/// but not identical (e.g. `decode(tokens:)` vs `decode(tokenIds:)`), and mlx-swift-lm does
/// not depend on swift-transformers, so no automatic conformance exists — this adapter is
/// the missing link, verified against both packages' source at implementation time.
public struct TransformersTokenizerLoader: TokenizerLoader, Sendable {
    public init() {}

    public func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let tokenizer = try await Tokenizers.AutoTokenizer.from(modelFolder: directory)
        return TokenizerAdapter(underlying: tokenizer)
    }
}

private struct TokenizerAdapter: MLXLMCommon.Tokenizer {
    let underlying: any Tokenizers.Tokenizer

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        underlying.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        underlying.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? {
        underlying.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        underlying.convertIdToToken(id)
    }

    var bosToken: String? { underlying.bosToken }
    var eosToken: String? { underlying.eosToken }
    var unknownToken: String? { underlying.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        try underlying.applyChatTemplate(
            messages: messages,
            tools: tools,
            additionalContext: additionalContext
        )
    }
}
