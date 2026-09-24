import Foundation
import Testing
@testable import AIChatRouterKit

@Suite("ProviderStreamChunk citations")
struct ProviderStreamChunkCitationsTests {
    @Test func chunkDefaultsToNoCitations() {
        let chunk = ProviderStreamChunk(deltaText: "hi")
        #expect(chunk.citations == nil)
    }

    @Test func chunkCanCarryCitations() {
        let citation = SearchCitation(url: "https://example.com", title: "Example")
        let chunk = ProviderStreamChunk(deltaText: "", isFinal: true, citations: [citation])
        #expect(chunk.citations?.count == 1)
        #expect(chunk.citations?.first?.url == "https://example.com")
        #expect(chunk.citations?.first?.title == "Example")
    }

    @Test func fakeEchoProviderIgnoresEnableWebSearchFlag() async throws {
        let provider = FakeEchoProvider()
        let descriptor = ProviderModelDescriptor(id: "echo", providerID: .localMLX, tier: .local, displayName: "Local")
        var sawFinal = false
        for try await chunk in provider.streamCompletion(
            model: descriptor, systemPrompt: nil, turns: [ChatTurn(role: .user, content: "hi")],
            maxOutputTokens: 50, enableWebSearch: true
        ) {
            if chunk.isFinal {
                sawFinal = true
                #expect(chunk.citations == nil)
            }
        }
        #expect(sawFinal)
    }
}
