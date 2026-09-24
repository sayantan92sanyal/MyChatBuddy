import Foundation

public struct LimiterConfig: Codable, Sendable, Equatable {
    /// Per-conversation token threshold. Warns only — never downgrades the tier,
    /// since long-running context is often exactly when a user wants to keep going.
    public var perConversationSoftCapTokens: Int?
    public var dailyBudgetUSD: Double?
    public var monthlyBudgetUSD: Double?
    /// Hard cap: once a tier's call count for today is reached, the router downgrades.
    public var perTierDailyCallCap: [ModelTier: Int]

    public init(
        perConversationSoftCapTokens: Int? = nil,
        dailyBudgetUSD: Double? = nil,
        monthlyBudgetUSD: Double? = nil,
        perTierDailyCallCap: [ModelTier: Int] = [:]
    ) {
        self.perConversationSoftCapTokens = perConversationSoftCapTokens
        self.dailyBudgetUSD = dailyBudgetUSD
        self.monthlyBudgetUSD = monthlyBudgetUSD
        self.perTierDailyCallCap = perTierDailyCallCap
    }

    public static let disabled = LimiterConfig()
}
