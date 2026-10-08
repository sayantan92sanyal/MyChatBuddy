import Foundation
import CoreImage
import MLXLMCommon

/// Runs completions on-device via MLX. Builds a fresh `ChatSession` re-primed with the
/// trimmed turn history on every call rather than holding a persistent session — simpler
/// for v1 and consistent with `LLMProvider` being otherwise stateless per call.
public struct LocalMLXProvider: LLMProvider, Sendable {
    public let id: ProviderID
    private let modelManager: LocalModelManager
    private let modelID: String
    private let kind: LocalModelOption.ModelKind

    public init(modelManager: LocalModelManager, modelID: String, kind: LocalModelOption.ModelKind = .text) {
        self.modelManager = modelManager
        self.modelID = modelID
        self.kind = kind
        self.id = kind == .vision ? .localVLM : .localMLX
    }

    public func isConfigured() async -> Bool {
        if case .ready = await modelManager.state(for: modelID) { return true }
        return false
    }

    public func streamCompletion(
        model: ProviderModelDescriptor,
        systemPrompt: String?,
        turns: [ChatTurn],
        maxOutputTokens: Int,
        enableWebSearch: Bool
    ) -> AsyncThrowingStream<ProviderStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let lastUserTurn = turns.last, lastUserTurn.role == .user else {
                        throw ProviderError.modelNotReady
                    }

                    // Decode before ever touching the model manager: a `.vision`-kind
                    // provider is only ever handed image data when the user actually
                    // attached one (routing bypass guarantees `.text`-kind turns are
                    // always empty here), so failing fast on bad image bytes avoids a
                    // pointless model load attempt.
                    let images: [UserInput.Image]
                    if kind == .vision {
                        images = try lastUserTurn.images.map { data in
                            guard let ciImage = CIImage(data: data) else {
                                throw ProviderError.decodingFailed("Could not decode attached image")
                            }
                            return .ciImage(ciImage)
                        }
                    } else {
                        images = []
                    }

                    let container = try await modelManager.loadedContainer(for: modelID, kind: kind)

                    let history: [Chat.Message] = turns.dropLast().map { turn in
                        switch turn.role {
                        case .system: return .system(turn.content)
                        case .user: return .user(turn.content)
                        case .assistant: return .assistant(turn.content)
                        }
                    }

                    let session = ChatSession(
                        container,
                        instructions: systemPrompt,
                        history: history,
                        generateParameters: GenerateParameters(
                            maxTokens: maxOutputTokens,
                            temperature: 0.7
                        )
                    )

                    let start = Date()
                    var promptTokens = 0
                    var completionTokens = 0
                    for try await generation in session.streamDetails(to: lastUserTurn.content, images: images) {
                        if let chunk = generation.chunk, !chunk.isEmpty {
                            continuation.yield(ProviderStreamChunk(deltaText: chunk))
                        }
                        if let info = generation.info {
                            promptTokens = info.promptTokenCount
                            completionTokens = info.generationTokenCount
                        }
                    }

                    let latencyMS = Int(Date().timeIntervalSince(start) * 1000)
                    continuation.yield(ProviderStreamChunk(
                        deltaText: "",
                        isFinal: true,
                        usage: TokenUsage(inputTokens: promptTokens, outputTokens: completionTokens),
                        latencyMS: latencyMS
                    ))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
