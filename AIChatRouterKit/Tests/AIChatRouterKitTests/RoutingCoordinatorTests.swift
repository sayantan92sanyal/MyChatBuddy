import Foundation
import Testing
@testable import AIChatRouterKit

private struct FakeQueryRouter: QueryRouter {
    let decision: RoutingDecision
    let error: Error?

    init(decision: RoutingDecision) {
        self.decision = decision
        self.error = nil
    }

    init(throwing error: Error) {
        self.decision = RoutingDecision(tier: .local, latencyMS: 0)
        self.error = error
    }

    func classify(_ context: RoutingContext) async throws -> RoutingDecision {
        if let error { throw error }
        return decision
    }
}

private enum FakeRouterError: Error {
    case boom
}

private struct PassthroughUsageLimiter: UsageLimiter {
    func applyCaps(to decision: RoutingDecision, conversationID: UUID) async -> RoutingDecision {
        decision
    }

    func recordUsage(
        conversationID: UUID,
        messageID: UUID?,
        providerID: ProviderID,
        tier: ModelTier,
        modelID: String,
        usage: TokenUsage
    ) async {}

    func spend(for period: UsagePeriod) async -> Double { 0 }
    func conversationTokenTotal(_ conversationID: UUID) async -> Int { 0 }
    func softCapWarning(for conversationID: UUID) async -> String? { nil }
}

private struct FakeNetworkStatus: NetworkStatusProvider {
    let isOnline: Bool
}

@Suite("RoutingCoordinator")
struct RoutingCoordinatorTests {
    @Test func decideReturnsAndLogsTheRouterDecision() async throws {
        let db = try AppDatabase.openInMemory()
        let conversations = ConversationStore(database: db)
        let logStore = RoutingLogStore(database: db)

        let conversation = Conversation(title: "Test")
        try await conversations.create(conversation)

        let router = FakeQueryRouter(decision: RoutingDecision(
            tier: .cloudAdvanced,
            reasoning: "complex reasoning required",
            latencyMS: 42
        ))
        let coordinator = RoutingCoordinator(router: router, logStore: logStore, usageLimiter: PassthroughUsageLimiter(), networkStatus: FakeNetworkStatus(isOnline: true))

        let context = RoutingContext(
            conversationID: conversation.id,
            recentTurns: [],
            candidateQuery: "Explain quantum entanglement in depth"
        )
        let decision = await coordinator.decide(context)

        #expect(decision.tier == .cloudAdvanced)
        #expect(decision.reasoning == "complex reasoning required")

        let logged = try await logStore.decisions(for: conversation.id)
        #expect(logged.count == 1)
        #expect(logged.first?.tier == .cloudAdvanced)
        #expect(logged.first?.query == "Explain quantum entanglement in depth")
    }

    @Test func fallsBackToLocalAndStillLogsWhenRouterThrows() async throws {
        let db = try AppDatabase.openInMemory()
        let conversations = ConversationStore(database: db)
        let logStore = RoutingLogStore(database: db)

        let conversation = Conversation(title: "Test")
        try await conversations.create(conversation)

        let router = FakeQueryRouter(throwing: FakeRouterError.boom)
        let coordinator = RoutingCoordinator(router: router, logStore: logStore, usageLimiter: PassthroughUsageLimiter(), networkStatus: FakeNetworkStatus(isOnline: true))

        let context = RoutingContext(
            conversationID: conversation.id,
            recentTurns: [],
            candidateQuery: "hi"
        )
        let decision = await coordinator.decide(context)

        #expect(decision.tier == .local)

        let logged = try await logStore.decisions(for: conversation.id)
        #expect(logged.count == 1)
        #expect(logged.first?.tier == .local)
    }

    @Test func forcesLocalWhenOffline() async throws {
        let db = try AppDatabase.openInMemory()
        let conversations = ConversationStore(database: db)
        let logStore = RoutingLogStore(database: db)

        let conversation = Conversation(title: "Test")
        try await conversations.create(conversation)

        let router = FakeQueryRouter(decision: RoutingDecision(tier: .cloudAdvanced, latencyMS: 10))
        let coordinator = RoutingCoordinator(
            router: router,
            logStore: logStore,
            usageLimiter: PassthroughUsageLimiter(),
            networkStatus: FakeNetworkStatus(isOnline: false)
        )

        let context = RoutingContext(conversationID: conversation.id, recentTurns: [], candidateQuery: "hi")
        let decision = await coordinator.decide(context)

        #expect(decision.tier == .local)
        #expect(decision.downgradedFrom == .cloudAdvanced)
        #expect(decision.downgradeReason?.contains("offline") == true)
    }
}
