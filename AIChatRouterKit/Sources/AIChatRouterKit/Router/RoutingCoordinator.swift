import Foundation

/// Orchestrates one routing decision: runs the `QueryRouter`, falls back safely if it
/// throws, consults the `UsageLimiter` (which may downgrade the tier under a cap),
/// forces `.local` when offline, and logs every decision (query, tier, reasoning,
/// latency) for later tuning.
public actor RoutingCoordinator {
    private let router: QueryRouter
    private let logStore: RoutingLogStore
    private let usageLimiter: UsageLimiter
    private let networkStatus: NetworkStatusProvider

    public init(
        router: QueryRouter,
        logStore: RoutingLogStore,
        usageLimiter: UsageLimiter,
        networkStatus: NetworkStatusProvider
    ) {
        self.router = router
        self.logStore = logStore
        self.usageLimiter = usageLimiter
        self.networkStatus = networkStatus
    }

    @discardableResult
    public func decide(_ context: RoutingContext) async -> RoutingDecision {
        let raw: RoutingDecision
        do {
            raw = try await router.classify(context)
        } catch {
            raw = RoutingDecision(
                tier: .local,
                reasoning: "classifier unavailable — safe fallback (\(error.localizedDescription))",
                latencyMS: 0
            )
        }

        var adjusted = await usageLimiter.applyCaps(to: raw, conversationID: context.conversationID)

        if adjusted.tier != .local, await !networkStatus.isOnline {
            adjusted.downgradedFrom = adjusted.downgradedFrom ?? adjusted.tier
            adjusted.tier = .local
            adjusted.downgradeReason = "You're offline — routed to the local model"
        }

        _ = try? await logStore.record(
            conversationID: context.conversationID,
            query: context.candidateQuery,
            decision: adjusted
        )

        return adjusted
    }
}
