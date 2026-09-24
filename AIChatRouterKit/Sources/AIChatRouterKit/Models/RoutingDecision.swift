import Foundation

/// The output of a `QueryRouter` classification pass. Distinct from the persisted
/// `RoutingDecisionRow` (see `RoutingLogStore`), which additionally carries the
/// query text, conversation, and message association for logging/tuning.
public struct RoutingDecision: Sendable, Codable, Equatable {
    public var tier: ModelTier
    public var reasoning: String?
    public var latencyMS: Int
    public var downgradedFrom: ModelTier?
    public var downgradeReason: String?

    public init(
        tier: ModelTier,
        reasoning: String? = nil,
        latencyMS: Int,
        downgradedFrom: ModelTier? = nil,
        downgradeReason: String? = nil
    ) {
        self.tier = tier
        self.reasoning = reasoning
        self.latencyMS = latencyMS
        self.downgradedFrom = downgradedFrom
        self.downgradeReason = downgradeReason
    }
}
