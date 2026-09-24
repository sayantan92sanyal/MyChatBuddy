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

    /// Set by the classifier when the query needs current/external info the model
    /// doesn't already have. Only cloud tiers can act on it (see `RoutingCoordinator`).
    public var needsWebSearch: Bool
    /// True when a usage cap (not offline) forced `tier` to `.local` while
    /// `needsWebSearch` was true — the caller should ask the user before proceeding,
    /// rather than silently picking a side.
    public var requiresSearchPermission: Bool
    /// The tier to resume at if search permission is granted. Always `.cloudFast`
    /// (the minimum viable tier for search) — never the original higher tier a
    /// complexity judgment may have wanted, since the permission ask is "let this
    /// search happen," not "restore full Advanced-tier spending."
    public var searchOverrideTier: ModelTier?

    public init(
        tier: ModelTier,
        reasoning: String? = nil,
        latencyMS: Int,
        downgradedFrom: ModelTier? = nil,
        downgradeReason: String? = nil,
        needsWebSearch: Bool = false,
        requiresSearchPermission: Bool = false,
        searchOverrideTier: ModelTier? = nil
    ) {
        self.tier = tier
        self.reasoning = reasoning
        self.latencyMS = latencyMS
        self.downgradedFrom = downgradedFrom
        self.downgradeReason = downgradeReason
        self.needsWebSearch = needsWebSearch
        self.requiresSearchPermission = requiresSearchPermission
        self.searchOverrideTier = searchOverrideTier
    }
}
