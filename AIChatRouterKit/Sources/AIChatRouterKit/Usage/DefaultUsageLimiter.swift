import Foundation

/// Default `UsageLimiter`. Reads `LimiterConfig` fresh from `AppSettingsStore` on every
/// call (same pattern as `ProviderRegistry`), so Settings changes take effect immediately.
public actor DefaultUsageLimiter: UsageLimiter {
    private let usageStore: UsageStore
    private let pricingTable: PricingTable
    private let settingsStore: AppSettingsStore

    public init(
        usageStore: UsageStore,
        pricingTable: PricingTable = PricingTable(),
        settingsStore: AppSettingsStore
    ) {
        self.usageStore = usageStore
        self.pricingTable = pricingTable
        self.settingsStore = settingsStore
    }

    public func applyCaps(to decision: RoutingDecision, conversationID: UUID) async -> RoutingDecision {
        let config = settingsStore.loadLimiterConfig()
        var current = decision

        while current.tier != .local {
            let reason: String
            if let overBudgetReason = await budgetReason(config: config) {
                reason = overBudgetReason
            } else if let callCap = config.perTierDailyCallCap[current.tier] {
                let count = await callCountToday(tier: current.tier)
                guard count >= callCap else { break }
                reason = "\(current.tier) call limit reached for today (\(callCap) calls)"
            } else {
                break
            }

            current.downgradedFrom = current.downgradedFrom ?? decision.tier
            current.tier = stepDown(current.tier)
            current.downgradeReason = reason
        }

        return current
    }

    public func recordUsage(
        conversationID: UUID,
        messageID: UUID?,
        providerID: ProviderID,
        tier: ModelTier,
        modelID: String,
        usage: TokenUsage
    ) async {
        let cost = pricingTable.estimatedCost(
            modelID: modelID,
            inputTokens: usage.inputTokens,
            outputTokens: usage.outputTokens
        )
        let record = UsageRecord(
            conversationID: conversationID,
            messageID: messageID,
            providerID: providerID,
            tier: tier,
            modelID: modelID,
            inputTokens: usage.inputTokens,
            outputTokens: usage.outputTokens,
            estimatedCostUSD: cost
        )
        try? await usageStore.record(record)
    }

    public func spend(for period: UsagePeriod) async -> Double {
        let (start, end) = periodBounds(for: period)
        return (try? await usageStore.totalSpend(from: start, to: end)) ?? 0
    }

    public func conversationTokenTotal(_ conversationID: UUID) async -> Int {
        (try? await usageStore.conversationTokenTotal(conversationID)) ?? 0
    }

    public func softCapWarning(for conversationID: UUID) async -> String? {
        guard let softCap = settingsStore.loadLimiterConfig().perConversationSoftCapTokens else {
            return nil
        }
        let total = await conversationTokenTotal(conversationID)
        guard total >= softCap else { return nil }
        return "This conversation has used \(total) tokens, past the configured soft cap of "
            + "\(softCap). You can keep going — this is just a heads-up."
    }

    // MARK: - Private

    private func budgetReason(config: LimiterConfig) async -> String? {
        if let dailyBudget = config.dailyBudgetUSD {
            let (start, end) = periodBounds(for: .daily)
            let spend = (try? await usageStore.totalSpend(from: start, to: end)) ?? 0
            if spend >= dailyBudget {
                return "Daily budget cap ($\(dailyBudget)) reached"
            }
        }
        if let monthlyBudget = config.monthlyBudgetUSD {
            let (start, end) = periodBounds(for: .monthly)
            let spend = (try? await usageStore.totalSpend(from: start, to: end)) ?? 0
            if spend >= monthlyBudget {
                return "Monthly budget cap ($\(monthlyBudget)) reached"
            }
        }
        return nil
    }

    private func callCountToday(tier: ModelTier) async -> Int {
        let (start, end) = periodBounds(for: .daily)
        return (try? await usageStore.callCount(tier: tier, from: start, to: end)) ?? 0
    }

    private func stepDown(_ tier: ModelTier) -> ModelTier {
        switch tier {
        case .cloudAdvanced: return .cloudFast
        case .cloudFast: return .local
        case .local: return .local
        }
    }

    private func periodBounds(for period: UsagePeriod) -> (Date, Date) {
        let calendar = Calendar.current
        let now = Date()
        switch period {
        case .daily:
            let start = calendar.startOfDay(for: now)
            let end = calendar.date(byAdding: .day, value: 1, to: start) ?? now
            return (start, end)
        case .monthly:
            let components = calendar.dateComponents([.year, .month], from: now)
            let start = calendar.date(from: components) ?? now
            let end = calendar.date(byAdding: .month, value: 1, to: start) ?? now
            return (start, end)
        }
    }
}
