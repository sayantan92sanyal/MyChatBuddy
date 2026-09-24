import Foundation

/// Orchestrates one routing decision: runs the `QueryRouter`, falls back safely if it
/// throws, applies the web-search toggle and local→cloudFast bump, consults the
/// `UsageLimiter` (which may downgrade the tier under a cap), flags a caps-vs-search
/// conflict for the UI to resolve rather than resolving it silently, forces `.local`
/// when offline, and logs every decision (query, tier, reasoning, latency) for later
/// tuning.
public actor RoutingCoordinator {
    private let router: QueryRouter
    private let logStore: RoutingLogStore
    private let usageLimiter: UsageLimiter
    private let networkStatus: NetworkStatusProvider
    private let settingsStore: AppSettingsStore

    public init(
        router: QueryRouter,
        logStore: RoutingLogStore,
        usageLimiter: UsageLimiter,
        networkStatus: NetworkStatusProvider,
        settingsStore: AppSettingsStore
    ) {
        self.router = router
        self.logStore = logStore
        self.usageLimiter = usageLimiter
        self.networkStatus = networkStatus
        self.settingsStore = settingsStore
    }

    @discardableResult
    public func decide(_ context: RoutingContext) async -> RoutingDecision {
        var raw: RoutingDecision
        do {
            raw = try await router.classify(context)
        } catch {
            raw = RoutingDecision(
                tier: .local,
                reasoning: "classifier unavailable — safe fallback (\(error.localizedDescription))",
                latencyMS: 0
            )
        }

        // Captured before suppression: the on-device classifier is a single small
        // model call that doesn't cleanly separate "needs current info" from "is
        // this FAST/ADVANCED-worthy" — a search-flavored query often comes back
        // with a cloud tier attached directly, not only via the bump below. That
        // tier judgment can't be trusted once search is off, since we can't tell
        // how much of it was genuine complexity vs. search-flavor bias.
        let classifierWantedSearch = raw.needsWebSearch
        let webSearchEnabled = settingsStore.loadWebSearchEnabled()

        // Toggle check happens before anything downstream can see needsWebSearch —
        // when off, it's as if the classifier never said SEARCH at all.
        if !webSearchEnabled {
            raw.needsWebSearch = false
        }

        // Search need always forces at least Cloud Fast — only cloud tiers can search.
        if raw.needsWebSearch, raw.tier == .local {
            raw.tier = .cloudFast
        }

        if !webSearchEnabled, classifierWantedSearch, raw.tier != .local {
            raw.downgradedFrom = raw.tier
            raw.downgradeReason = "Web search is off — staying local rather than spending a cloud call on a query that needed current info"
            raw.tier = .local
        }

        var adjusted = await usageLimiter.applyCaps(to: raw, conversationID: context.conversationID)

        // A cap (not offline) forced this to .local while search was needed: don't
        // resolve the conflict silently — flag it for the UI to ask permission.
        // The offered override is always cloudFast (minimum viable for search),
        // never `downgradedFrom` (which records the *original* pre-cascade tier,
        // e.g. cloudAdvanced, and would ask for more spending than search needs).
        if raw.needsWebSearch, adjusted.tier == .local, adjusted.downgradedFrom != nil {
            adjusted.requiresSearchPermission = true
            adjusted.searchOverrideTier = .cloudFast
        }

        if adjusted.tier != .local, await !networkStatus.isOnline {
            adjusted.downgradedFrom = adjusted.downgradedFrom ?? adjusted.tier
            adjusted.tier = .local
            adjusted.downgradeReason = "You're offline — routed to the local model"
            // Offline is a hard constraint, not a policy choice — no permission ask.
            adjusted.requiresSearchPermission = false
            adjusted.searchOverrideTier = nil
        }

        _ = try? await logStore.record(
            conversationID: context.conversationID,
            query: context.candidateQuery,
            decision: adjusted
        )

        return adjusted
    }
}
