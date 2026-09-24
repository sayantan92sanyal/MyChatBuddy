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

/// Simulates a cap cascade: downgrades whatever tier it's given straight to `.local`
/// in one step, recording the *original* tier as `downgradedFrom` — exactly like
/// `DefaultUsageLimiter`'s real cascade does when every cloud tier is capped.
private struct AlwaysDowngradesToLocalUsageLimiter: UsageLimiter {
    func applyCaps(to decision: RoutingDecision, conversationID: UUID) async -> RoutingDecision {
        guard decision.tier != .local else { return decision }
        var downgraded = decision
        downgraded.downgradedFrom = decision.tier
        downgraded.tier = .local
        downgraded.downgradeReason = "budget cap reached"
        return downgraded
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

private func settingsStore(webSearchEnabled: Bool = true) -> AppSettingsStore {
    let suiteName = "RoutingCoordinatorTests-\(UUID().uuidString)"
    let store = AppSettingsStore(defaults: UserDefaults(suiteName: suiteName)!)
    store.saveWebSearchEnabled(webSearchEnabled)
    return store
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
        let coordinator = RoutingCoordinator(
            router: router,
            logStore: logStore,
            usageLimiter: PassthroughUsageLimiter(),
            networkStatus: FakeNetworkStatus(isOnline: true),
            settingsStore: settingsStore()
        )

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
        let coordinator = RoutingCoordinator(
            router: router,
            logStore: logStore,
            usageLimiter: PassthroughUsageLimiter(),
            networkStatus: FakeNetworkStatus(isOnline: true),
            settingsStore: settingsStore()
        )

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
            networkStatus: FakeNetworkStatus(isOnline: false),
            settingsStore: settingsStore()
        )

        let context = RoutingContext(conversationID: conversation.id, recentTurns: [], candidateQuery: "hi")
        let decision = await coordinator.decide(context)

        #expect(decision.tier == .local)
        #expect(decision.downgradedFrom == .cloudAdvanced)
        #expect(decision.downgradeReason?.contains("offline") == true)
    }

    @Test func searchNeedBumpsLocalTierToCloudFast() async throws {
        let db = try AppDatabase.openInMemory()
        let conversations = ConversationStore(database: db)
        let logStore = RoutingLogStore(database: db)

        let conversation = Conversation(title: "Test")
        try await conversations.create(conversation)

        let router = FakeQueryRouter(decision: RoutingDecision(tier: .local, latencyMS: 10, needsWebSearch: true))
        let coordinator = RoutingCoordinator(
            router: router,
            logStore: logStore,
            usageLimiter: PassthroughUsageLimiter(),
            networkStatus: FakeNetworkStatus(isOnline: true),
            settingsStore: settingsStore()
        )

        let context = RoutingContext(conversationID: conversation.id, recentTurns: [], candidateQuery: "today's news")
        let decision = await coordinator.decide(context)

        #expect(decision.tier == .cloudFast)
        #expect(decision.needsWebSearch == true)
        #expect(decision.requiresSearchPermission == false)
    }

    @Test func webSearchToggleOffSuppressesSearchFlagAndTierBump() async throws {
        let db = try AppDatabase.openInMemory()
        let conversations = ConversationStore(database: db)
        let logStore = RoutingLogStore(database: db)

        let conversation = Conversation(title: "Test")
        try await conversations.create(conversation)

        let router = FakeQueryRouter(decision: RoutingDecision(tier: .local, latencyMS: 10, needsWebSearch: true))
        let coordinator = RoutingCoordinator(
            router: router,
            logStore: logStore,
            usageLimiter: PassthroughUsageLimiter(),
            networkStatus: FakeNetworkStatus(isOnline: true),
            settingsStore: settingsStore(webSearchEnabled: false)
        )

        let context = RoutingContext(conversationID: conversation.id, recentTurns: [], candidateQuery: "today's news")
        let decision = await coordinator.decide(context)

        // Toggle off: the tier bump never happens because needsWebSearch was
        // suppressed before the bump check ran.
        #expect(decision.tier == .local)
        #expect(decision.needsWebSearch == false)
        #expect(decision.requiresSearchPermission == false)
    }

    @Test func capCascadeConflictingWithSearchNeedOffersCloudFastNotOriginalTier() async throws {
        let db = try AppDatabase.openInMemory()
        let conversations = ConversationStore(database: db)
        let logStore = RoutingLogStore(database: db)

        let conversation = Conversation(title: "Test")
        try await conversations.create(conversation)

        // Router wants Advanced + search; the fake limiter simulates a full cascade
        // (as DefaultUsageLimiter's real loop would when every cloud tier is capped)
        // landing on .local with downgradedFrom == .cloudAdvanced.
        let router = FakeQueryRouter(decision: RoutingDecision(
            tier: .cloudAdvanced, latencyMS: 10, needsWebSearch: true
        ))
        let coordinator = RoutingCoordinator(
            router: router,
            logStore: logStore,
            usageLimiter: AlwaysDowngradesToLocalUsageLimiter(),
            networkStatus: FakeNetworkStatus(isOnline: true),
            settingsStore: settingsStore()
        )

        let context = RoutingContext(conversationID: conversation.id, recentTurns: [], candidateQuery: "today's stock prices, analyze deeply")
        let decision = await coordinator.decide(context)

        #expect(decision.tier == .local)
        #expect(decision.requiresSearchPermission == true)
        // The critical assertion: offered override is cloudFast (minimum viable),
        // NOT .cloudAdvanced (which `downgradedFrom` would say if reused directly).
        #expect(decision.searchOverrideTier == .cloudFast)
        #expect(decision.downgradedFrom == .cloudAdvanced)
    }

    @Test func offlineNeverTriggersSearchPermissionEvenWithSearchNeed() async throws {
        let db = try AppDatabase.openInMemory()
        let conversations = ConversationStore(database: db)
        let logStore = RoutingLogStore(database: db)

        let conversation = Conversation(title: "Test")
        try await conversations.create(conversation)

        let router = FakeQueryRouter(decision: RoutingDecision(
            tier: .cloudFast, latencyMS: 10, needsWebSearch: true
        ))
        let coordinator = RoutingCoordinator(
            router: router,
            logStore: logStore,
            usageLimiter: PassthroughUsageLimiter(),
            networkStatus: FakeNetworkStatus(isOnline: false),
            settingsStore: settingsStore()
        )

        let context = RoutingContext(conversationID: conversation.id, recentTurns: [], candidateQuery: "today's news")
        let decision = await coordinator.decide(context)

        #expect(decision.tier == .local)
        #expect(decision.requiresSearchPermission == false)
        #expect(decision.searchOverrideTier == nil)
        #expect(decision.downgradeReason?.contains("offline") == true)
    }
}
