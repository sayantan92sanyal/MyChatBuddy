import Foundation
import MLXLMCommon

/// Runs completions on-device via MLX. Builds a fresh `ChatSession` re-primed with the
/// trimmed turn history on every call rather than holding a persistent session — simpler
/// for v1 and consistent with `LLMProvider` being otherwise stateless per call.
public struct LocalMLXProvider: LLMProvider, Sendable {
    public let id: ProviderID = .localMLX

    private let modelManager: LocalModelManager
    private let modelID: String

    public init(modelManager: LocalModelManager, modelID: String) {
        self.modelManager = modelManager
        self.modelID = modelID
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

                    let container = try await modelManager.loadedContainer(for: modelID, kind: .text)

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
                    for try await generation in session.streamDetails(to: lastUserTurn.content) {
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
