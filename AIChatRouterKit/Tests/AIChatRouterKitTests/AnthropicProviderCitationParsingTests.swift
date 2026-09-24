import Foundation
import Testing
@testable import AIChatRouterKit

@Suite("AnthropicProvider web search")
struct AnthropicProviderCitationParsingTests {
    @Test func isConfiguredFalseWithoutAPIKey() async throws {
        let suiteName = "AnthropicProviderCitationParsingTests-\(UUID().uuidString)"
        let keychain = KeychainStore(service: suiteName)
        let provider = AnthropicProvider(keychain: keychain)
        #expect(await provider.isConfigured() == false)
    }

    @Test func missingAPIKeyThrowsBeforeAnyNetworkCall() async throws {
        let suiteName = "AnthropicProviderCitationParsingTests-\(UUID().uuidString)"
        let keychain = KeychainStore(service: suiteName)
        let provider = AnthropicProvider(keychain: keychain)
        let descriptor = ProviderModelDescriptor(
            id: "claude-sonnet-4-5", providerID: .anthropic, tier: .cloudFast, displayName: "Sonnet"
        )

        await #expect(throws: ProviderError.self) {
            for try await _ in provider.streamCompletion(
                model: descriptor, systemPrompt: nil,
                turns: [ChatTurn(role: .user, content: "hi")],
                maxOutputTokens: 50, enableWebSearch: true
            ) {}
        }
    }
}
