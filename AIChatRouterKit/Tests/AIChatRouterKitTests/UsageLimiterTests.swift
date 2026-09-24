import Foundation
import Testing
@testable import AIChatRouterKit

@Suite("DefaultUsageLimiter")
struct UsageLimiterTests {
    private func makeLimiter(
        config: LimiterConfig,
        usageStore: UsageStore
    ) -> DefaultUsageLimiter {
        let suiteName = "UsageLimiterTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let settingsStore = AppSettingsStore(defaults: defaults)
        settingsStore.saveLimiterConfig(config)
        return DefaultUsageLimiter(usageStore: usageStore, settingsStore: settingsStore)
    }

    @Test func perTierCallCapDowngradesAdvancedToFast() async throws {
        let db = try AppDatabase.openInMemory()
        let usageStore = UsageStore(database: db)
        let conversationID = UUID()

        // Two prior cloudAdvanced calls already recorded today.
        for _ in 0..<2 {
            try await usageStore.record(UsageRecord(
                conversationID: conversationID,
                providerID: .anthropic,
                tier: .cloudAdvanced,
                modelID: "claude-opus-4-1",
                inputTokens: 100,
                outputTokens: 100
            ))
        }

        let limiter = makeLimiter(
            config: LimiterConfig(perTierDailyCallCap: [.cloudAdvanced: 2]),
            usageStore: usageStore
        )

        let decision = RoutingDecision(tier: .cloudAdvanced, latencyMS: 10)
        let adjusted = await limiter.applyCaps(to: decision, conversationID: conversationID)

        #expect(adjusted.tier == .cloudFast)
        #expect(adjusted.downgradedFrom == .cloudAdvanced)
        #expect(adjusted.downgradeReason != nil)
    }

    @Test func dailyBudgetCapCascadesAllTheWayToLocal() async throws {
        let db = try AppDatabase.openInMemory()
        let usageStore = UsageStore(database: db)
        let conversationID = UUID()

        try await usageStore.record(UsageRecord(
            conversationID: conversationID,
            providerID: .anthropic,
            tier: .cloudAdvanced,
            modelID: "claude-opus-4-1",
            inputTokens: 1_000_000,
            outputTokens: 1_000_000,
            estimatedCostUSD: 10.0
        ))

        let limiter = makeLimiter(
            config: LimiterConfig(dailyBudgetUSD: 5.0),
            usageStore: usageStore
        )

        let decision = RoutingDecision(tier: .cloudAdvanced, latencyMS: 10)
        let adjusted = await limiter.applyCaps(to: decision, conversationID: conversationID)

        // Over budget applies to every cloud tier, so it cascades all the way to local.
        #expect(adjusted.tier == .local)
        #expect(adjusted.downgradedFrom == .cloudAdvanced)
    }

    @Test func underCapsLeavesDecisionUnchanged() async throws {
        let db = try AppDatabase.openInMemory()
        let usageStore = UsageStore(database: db)
        let conversationID = UUID()

        let limiter = makeLimiter(config: .disabled, usageStore: usageStore)

        let decision = RoutingDecision(tier: .cloudFast, reasoning: "moderate", latencyMS: 10)
        let adjusted = await limiter.applyCaps(to: decision, conversationID: conversationID)

        #expect(adjusted.tier == .cloudFast)
        #expect(adjusted.downgradedFrom == nil)
        #expect(adjusted.downgradeReason == nil)
    }

    @Test func softCapWarnsButNeverChangesTier() async throws {
        let db = try AppDatabase.openInMemory()
        let usageStore = UsageStore(database: db)
        let conversationID = UUID()

        try await usageStore.record(UsageRecord(
            conversationID: conversationID,
            providerID: .anthropic,
            tier: .cloudFast,
            modelID: "claude-sonnet-4-5",
            inputTokens: 5_000,
            outputTokens: 5_000
        ))

        let limiter = makeLimiter(
            config: LimiterConfig(perConversationSoftCapTokens: 5_000),
            usageStore: usageStore
        )

        let decision = RoutingDecision(tier: .cloudAdvanced, latencyMS: 10)
        let adjusted = await limiter.applyCaps(to: decision, conversationID: conversationID)

        // Soft cap must never touch the tier — only a hard cap does.
        #expect(adjusted.tier == .cloudAdvanced)
        #expect(adjusted.downgradedFrom == nil)

        let warning = await limiter.softCapWarning(for: conversationID)
        #expect(warning != nil)
        #expect(warning?.contains("10000") == true)
    }

    @Test func recordUsagePersistsWithEstimatedCost() async throws {
        let db = try AppDatabase.openInMemory()
        let usageStore = UsageStore(database: db)
        let conversationID = UUID()

        let limiter = makeLimiter(config: .disabled, usageStore: usageStore)
        await limiter.recordUsage(
            conversationID: conversationID,
            messageID: nil,
            providerID: .anthropic,
            tier: .cloudAdvanced,
            modelID: "claude-opus-4-1",
            usage: TokenUsage(inputTokens: 1_000_000, outputTokens: 1_000_000)
        )

        let events = try await usageStore.events(for: conversationID)
        #expect(events.count == 1)
        #expect(events.first?.estimatedCostUSD ?? 0 > 0)
    }
}
