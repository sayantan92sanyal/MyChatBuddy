import Foundation
import Testing
@testable import AIChatRouterKit

@Suite("ContextWindowBuilder")
struct ContextWindowBuilderTests {
    private func message(_ role: Message.Role, _ content: String, offset: TimeInterval) -> Message {
        Message(
            conversationID: UUID(),
            role: role,
            content: content,
            createdAt: Date(timeIntervalSince1970: offset)
        )
    }

    @Test func returnsAllTurnsWhenWithinBudget() {
        let messages = [
            message(.user, "hi", offset: 1),
            message(.assistant, "hello", offset: 2),
            message(.user, "how are you?", offset: 3)
        ]
        let turns = ContextWindowBuilder(maxTurns: 20, maxCharacters: 10_000).build(from: messages)

        #expect(turns.count == 3)
        #expect(turns[0].role == .user)
        #expect(turns[0].content == "hi")
        #expect(turns.last?.content == "how are you?")
    }

    @Test func capsAtMaxTurns() {
        let messages = (0..<10).map { message(.user, "message \($0)", offset: TimeInterval($0)) }
        let turns = ContextWindowBuilder(maxTurns: 3, maxCharacters: 10_000).build(from: messages)

        #expect(turns.count == 3)
        #expect(turns.map(\.content) == ["message 7", "message 8", "message 9"])
    }

    @Test func stopsAddingOlderTurnsOnceCharacterBudgetExceeded() {
        let messages = [
            message(.user, String(repeating: "a", count: 50), offset: 1),
            message(.assistant, String(repeating: "b", count: 50), offset: 2),
            message(.user, String(repeating: "c", count: 50), offset: 3)
        ]
        // Budget only fits the most recent message plus a little slack.
        let turns = ContextWindowBuilder(maxTurns: 20, maxCharacters: 60).build(from: messages)

        #expect(turns.count == 1)
        #expect(turns.first?.content == String(repeating: "c", count: 50))
    }

    @Test func neverReturnsEmptyWhenMessagesExist() {
        let messages = [message(.user, String(repeating: "x", count: 500), offset: 1)]
        let turns = ContextWindowBuilder(maxTurns: 20, maxCharacters: 1).build(from: messages)

        // Even under a tiny budget, at least the newest turn is always included.
        #expect(turns.count == 1)
    }
}
