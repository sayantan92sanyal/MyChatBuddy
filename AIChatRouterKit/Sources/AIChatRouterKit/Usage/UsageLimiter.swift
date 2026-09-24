import Foundation

public enum UsagePeriod: Sendable {
    case daily
    case monthly
}

/// Consulted by `RoutingCoordinator` before finalizing a tier. Distinguishes soft caps
/// (warn only) from hard caps (daily/monthly budget, per-tier call limits — these
/// downgrade the tier rather than failing the request outright).
public protocol UsageLimiter: Sendable {
    func applyCaps(to decision: RoutingDecision, conversationID: UUID) async -> RoutingDecision

    func recordUsage(
        conversationID: UUID,
        messageID: UUID?,
        providerID: ProviderID,
        tier: ModelTier,
        modelID: String,
        usage: TokenUsage
    ) async

    func spend(for period: UsagePeriod) async -> Double
    func conversationTokenTotal(_ conversationID: UUID) async -> Int
    func softCapWarning(for conversationID: UUID) async -> String?
}
