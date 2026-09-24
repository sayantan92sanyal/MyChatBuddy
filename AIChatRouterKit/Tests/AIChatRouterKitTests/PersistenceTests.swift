import Foundation
import Testing
@testable import AIChatRouterKit

@Suite("Persistence round-trips")
struct PersistenceTests {
    @Test func conversationCreateFetchUpdate() async throws {
        let db = try AppDatabase.openInMemory()
        let store = ConversationStore(database: db)

        let conversation = Conversation(title: "Test Conversation")
        try await store.create(conversation)

        let fetched = try await store.fetch(id: conversation.id)
        #expect(fetched?.title == "Test Conversation")
        #expect(fetched?.tokenTotalInput == 0)

        try await store.addTokenUsage(id: conversation.id, input: 100, output: 50)
        let updated = try await store.fetch(id: conversation.id)
        #expect(updated?.tokenTotalInput == 100)
        #expect(updated?.tokenTotalOutput == 50)

        let all = try await store.fetchAll()
        #expect(all.count == 1)
    }

    @Test func messagesPersistAndOrderByCreatedAt() async throws {
        let db = try AppDatabase.openInMemory()
        let conversations = ConversationStore(database: db)
        let messages = MessageStore(database: db)

        let conversation = Conversation(title: "Chat")
        try await conversations.create(conversation)

        let first = Message(
            conversationID: conversation.id,
            role: .user,
            content: "Hello",
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let second = Message(
            conversationID: conversation.id,
            role: .assistant,
            content: "Hi there",
            createdAt: Date(timeIntervalSince1970: 2),
            providerID: .localMLX,
            modelID: "llama-3.2-3b-instruct-4bit",
            tier: .local,
            inputTokens: 12,
            outputTokens: 8,
            latencyMS: 350
        )
        try await messages.append(first)
        try await messages.append(second)

        let fetched = try await messages.messages(for: conversation.id)
        #expect(fetched.count == 2)
        #expect(fetched.first?.content == "Hello")
        #expect(fetched.last?.tier == .local)
        #expect(fetched.last?.providerID == .localMLX)
    }

    @Test func routingDecisionsAreLoggedAndQueryable() async throws {
        let db = try AppDatabase.openInMemory()
        let conversations = ConversationStore(database: db)
        let routingLog = RoutingLogStore(database: db)

        let conversation = Conversation(title: "Routing Test")
        try await conversations.create(conversation)

        let decision = RoutingDecision(
            tier: .cloudFast,
            reasoning: "moderate complexity",
            latencyMS: 220,
            downgradedFrom: .cloudAdvanced,
            downgradeReason: "daily advanced-tier cap reached"
        )
        try await routingLog.record(
            conversationID: conversation.id,
            query: "Summarize this document",
            decision: decision
        )

        let logged = try await routingLog.decisions(for: conversation.id)
        #expect(logged.count == 1)
        #expect(logged.first?.tier == .cloudFast)
        #expect(logged.first?.downgradedFrom == .cloudAdvanced)
        #expect(logged.first?.downgradeReason == "daily advanced-tier cap reached")
    }

    @Test func usageEventsAggregateByProviderAndTier() async throws {
        let db = try AppDatabase.openInMemory()
        let conversations = ConversationStore(database: db)
        let usage = UsageStore(database: db)

        let conversation = Conversation(title: "Usage Test")
        try await conversations.create(conversation)

        let start = Date(timeIntervalSince1970: 0)
        let end = Date(timeIntervalSince1970: 1_000_000)

        try await usage.record(UsageRecord(
            conversationID: conversation.id,
            providerID: .anthropic,
            tier: .cloudAdvanced,
            modelID: "claude-opus",
            inputTokens: 500,
            outputTokens: 300,
            estimatedCostUSD: 0.45,
            createdAt: Date(timeIntervalSince1970: 100)
        ))
        try await usage.record(UsageRecord(
            conversationID: conversation.id,
            providerID: .anthropic,
            tier: .cloudAdvanced,
            modelID: "claude-opus",
            inputTokens: 200,
            outputTokens: 100,
            estimatedCostUSD: 0.18,
            createdAt: Date(timeIntervalSince1970: 200)
        ))
        try await usage.record(UsageRecord(
            conversationID: conversation.id,
            providerID: .localMLX,
            tier: .local,
            modelID: "llama-3.2-3b-instruct-4bit",
            inputTokens: 50,
            outputTokens: 40,
            estimatedCostUSD: 0,
            createdAt: Date(timeIntervalSince1970: 300)
        ))

        let totals = try await usage.totals(from: start, to: end)
        let advancedTotal = totals.first { $0.tier == .cloudAdvanced }
        #expect(advancedTotal?.inputTokens == 700)
        #expect(advancedTotal?.outputTokens == 400)
        #expect(advancedTotal?.costUSD ?? 0 > 0.62)

        let localTotal = totals.first { $0.tier == .local }
        #expect(localTotal?.inputTokens == 50)

        let spend = try await usage.totalSpend(from: start, to: end)
        #expect(spend > 0.62)

        let advancedCallCount = try await usage.callCount(tier: .cloudAdvanced, from: start, to: end)
        #expect(advancedCallCount == 2)

        let conversationTotal = try await usage.conversationTokenTotal(conversation.id)
        #expect(conversationTotal == 500 + 300 + 200 + 100 + 50 + 40)
    }

    @Test func deletingConversationCascadesMessagesAndRoutingLogs() async throws {
        let db = try AppDatabase.openInMemory()
        let conversations = ConversationStore(database: db)
        let messages = MessageStore(database: db)
        let routingLog = RoutingLogStore(database: db)

        let conversation = Conversation(title: "To Delete")
        try await conversations.create(conversation)
        try await messages.append(Message(conversationID: conversation.id, role: .user, content: "hi"))
        try await routingLog.record(
            conversationID: conversation.id,
            query: "hi",
            decision: RoutingDecision(tier: .local, latencyMS: 10)
        )

        try await conversations.delete(id: conversation.id)

        let remainingMessages = try await messages.messages(for: conversation.id)
        let remainingDecisions = try await routingLog.decisions(for: conversation.id)
        #expect(remainingMessages.isEmpty)
        #expect(remainingDecisions.isEmpty)
    }
}
