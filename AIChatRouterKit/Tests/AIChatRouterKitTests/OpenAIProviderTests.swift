import Foundation
import Testing
@testable import AIChatRouterKit

@Suite("OpenAIProvider web search")
struct OpenAIProviderTests {
    @Test func isConfiguredFalseWithoutAPIKey() async throws {
        let suiteName = "OpenAIProviderTests-\(UUID().uuidString)"
        let keychain = KeychainStore(service: suiteName)
        let provider = OpenAIProvider(keychain: keychain)
        #expect(await provider.isConfigured() == false)
    }

    @Test func missingAPIKeyThrowsBeforeAnyNetworkCall() async throws {
        let suiteName = "OpenAIProviderTests-\(UUID().uuidString)"
        let keychain = KeychainStore(service: suiteName)
        let provider = OpenAIProvider(keychain: keychain)
        let descriptor = ProviderModelDescriptor(
            id: "gpt-4o-mini", providerID: .openAI, tier: .cloudFast, displayName: "GPT-4o mini"
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
