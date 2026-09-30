import Foundation
import Testing
import MLXLMCommon
@testable import AIChatRouterKit

@Suite("LocalMLXProvider image handling")
struct LocalMLXProviderImageHandlingTests {
    private struct FailingDownloader: Downloader {
        struct Failure: Error {}
        func download(
            id: String, revision: String?, matching patterns: [String],
            useLatest: Bool, progressHandler: @Sendable @escaping (Progress) -> Void
        ) async throws -> URL {
            throw Failure()
        }
    }

    private struct UnreachableTokenizerLoader: TokenizerLoader {
        func load(from directory: URL) async throws -> any Tokenizer {
            fatalError("must not be reached in this test")
        }
    }

    private func makeManager() -> LocalModelManager {
        LocalModelManager(downloader: FailingDownloader(), tokenizerLoader: UnreachableTokenizerLoader())
    }

    @Test func visionKindThrowsDecodingFailedForUndecodableImageWithoutTouchingTheDownloader() async throws {
        let provider = LocalMLXProvider(modelManager: makeManager(), modelID: "any-id", kind: .vision)
        let turns = [ChatTurn(role: .user, content: "what is this?", images: [Data([0x00, 0x01, 0x02])])]
        let descriptor = ProviderModelDescriptor(id: "any-id", providerID: .localVLM, tier: .local, displayName: "Test Vision")
        let stream = provider.streamCompletion(
            model: descriptor, systemPrompt: nil, turns: turns, maxOutputTokens: 10, enableWebSearch: false
        )

        do {
            for try await _ in stream { Issue.record("Expected a thrown error") }
        } catch ProviderError.decodingFailed(let reason) {
            #expect(reason == "Could not decode attached image")
        } catch {
            Issue.record("Expected ProviderError.decodingFailed, got \(error)")
        }
    }

    @Test func textKindIgnoresTheImagesFieldAndProceedsToLoadTheModel() async throws {
        let provider = LocalMLXProvider(modelManager: makeManager(), modelID: "any-id", kind: .text)
        let turns = [ChatTurn(role: .user, content: "hi", images: [Data([0x00, 0x01, 0x02])])]
        let descriptor = ProviderModelDescriptor(id: "any-id", providerID: .localMLX, tier: .local, displayName: "Test Text")
        let stream = provider.streamCompletion(
            model: descriptor, systemPrompt: nil, turns: turns, maxOutputTokens: 10, enableWebSearch: false
        )

        do {
            for try await _ in stream { Issue.record("Expected a thrown error") }
        } catch is FailingDownloader.Failure {
            // Expected: the .text path skipped image decoding entirely and reached
            // the (fake, failing) download step instead.
        } catch {
            Issue.record("Expected FailingDownloader.Failure (proving images were never decoded), got \(error)")
        }
    }
}
