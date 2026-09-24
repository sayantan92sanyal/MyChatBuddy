import Foundation

/// Trims persisted conversation history into a rolling context window, bounded by
/// turn count and a character budget (a token-count proxy — no tokenizer is available
/// at this generic layer, and character count is a reasonable approximation for v1).
public struct ContextWindowBuilder: Sendable {
    public let maxTurns: Int
    public let maxCharacters: Int

    public init(maxTurns: Int = 20, maxCharacters: Int = 12000) {
        self.maxTurns = maxTurns
        self.maxCharacters = maxCharacters
    }

    public func build(from messages: [Message]) -> [ChatTurn] {
        let recent = messages.suffix(maxTurns)
        var turns: [ChatTurn] = []
        var totalCharacters = 0

        for message in recent.reversed() {
            let role = ChatTurn.Role(rawValue: message.role.rawValue) ?? .user
            let turn = ChatTurn(role: role, content: message.content)
            totalCharacters += turn.content.count
            if totalCharacters > maxCharacters, !turns.isEmpty {
                break
            }
            turns.insert(turn, at: 0)
        }

        return turns
    }
}
