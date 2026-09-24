import Foundation
import Testing
@testable import AIChatRouterKit

@Suite("PromptedLocalQueryRouter parsing")
struct PromptedLocalQueryRouterParsingTests {
    @Test func plainLocalHasNoSearchFlag() {
        let decision = PromptedLocalQueryRouter.parse(response: "LOCAL", latencyMS: 5)
        #expect(decision.tier == .local)
        #expect(decision.needsWebSearch == false)
    }

    @Test func fastWithSearchTokenSetsFlag() {
        let decision = PromptedLocalQueryRouter.parse(response: "FAST SEARCH", latencyMS: 5)
        #expect(decision.tier == .cloudFast)
        #expect(decision.needsWebSearch == true)
    }

    @Test func localWithSearchTokenSetsFlagButDoesNotBumpTierHere() {
        // The router only reports the need; RoutingCoordinator (Task 3) owns the
        // toggle-check-then-bump decision, so parse() must NOT bump tier itself.
        let decision = PromptedLocalQueryRouter.parse(response: "LOCAL SEARCH", latencyMS: 5)
        #expect(decision.tier == .local)
        #expect(decision.needsWebSearch == true)
    }

    @Test func advancedWithSearchTokenAndReasoningLine() {
        let decision = PromptedLocalQueryRouter.parse(
            response: "ADVANCED SEARCH\nNeeds today's stock prices and deep analysis",
            latencyMS: 5
        )
        #expect(decision.tier == .cloudAdvanced)
        #expect(decision.needsWebSearch == true)
        #expect(decision.reasoning == "Needs today's stock prices and deep analysis")
    }

    @Test func searchTokenIsCaseInsensitive() {
        let decision = PromptedLocalQueryRouter.parse(response: "fast search", latencyMS: 5)
        #expect(decision.tier == .cloudFast)
        #expect(decision.needsWebSearch == true)
    }

    @Test func researchOnFirstLineDoesNotFalselySetSearchFlag() {
        // "SEARCH" must match as a whole word, not as a substring of "RESEARCH" —
        // within the tight 12-token budget the model can plausibly write
        // "ADVANCED - research-heavy" on the first line itself, and that must not
        // be mistaken for the SEARCH token.
        let decision = PromptedLocalQueryRouter.parse(
            response: "ADVANCED - research-heavy",
            latencyMS: 5
        )
        #expect(decision.tier == .cloudAdvanced)
        #expect(decision.needsWebSearch == false)
    }
}
