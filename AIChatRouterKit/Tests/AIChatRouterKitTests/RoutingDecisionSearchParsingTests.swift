import Foundation
import Testing
@testable import AIChatRouterKit

@Suite("RoutingDecision search fields")
struct RoutingDecisionSearchParsingTests {
    @Test func defaultsToNoSearchNeeded() {
        let decision = RoutingDecision(tier: .local, latencyMS: 10)
        #expect(decision.needsWebSearch == false)
        #expect(decision.requiresSearchPermission == false)
        #expect(decision.searchOverrideTier == nil)
    }

    @Test func canBeConstructedWithSearchFlagsSet() {
        let decision = RoutingDecision(
            tier: .cloudFast,
            latencyMS: 10,
            needsWebSearch: true,
            requiresSearchPermission: true,
            searchOverrideTier: .cloudFast
        )
        #expect(decision.needsWebSearch == true)
        #expect(decision.requiresSearchPermission == true)
        #expect(decision.searchOverrideTier == .cloudFast)
    }
}
