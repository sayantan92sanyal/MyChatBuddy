import Foundation
import Testing
@testable import AIChatRouterKit

@Suite("LLMProvider.supportsWebSearch")
struct ProviderSupportsWebSearchTests {
    @Test func anthropicSupportsWebSearch() {
        #expect(AnthropicProvider().supportsWebSearch == true)
    }

    @Test func openAIDoesNotSupportWebSearchYet() {
        // OpenAI's web-search wiring is deferred (no key was available to verify
        // the real endpoint shape — see the execution ledger's Task 7 ruling); it
        // must not claim search support it doesn't actually implement.
        #expect(OpenAIProvider().supportsWebSearch == false)
    }

    @Test func fakeEchoDoesNotSupportWebSearch() {
        #expect(FakeEchoProvider().supportsWebSearch == false)
    }
}
