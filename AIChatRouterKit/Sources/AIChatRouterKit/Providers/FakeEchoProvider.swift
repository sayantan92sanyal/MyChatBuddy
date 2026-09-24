import Foundation

/// Development-only provider that echoes the last user turn back word-by-word after
/// an artificial delay, fabricating plausible token counts. Exists purely to validate
/// the chat UI loop (persistence, streaming rendering, badges) before any real
/// network/model integration lands.
public struct FakeEchoProvider: LLMProvider, Sendable {
    public let id: ProviderID = .localMLX

    public init() {}

    public func isConfigured() async -> Bool { true }

    public func streamCompletion(
        model: ProviderModelDescriptor,
        systemPrompt: String?,
        turns: [ChatTurn],
        maxOutputTokens: Int,
        enableWebSearch: Bool
    ) -> AsyncThrowingStream<ProviderStreamChunk, Error> {
        let reply = "Echo: " + (turns.last(where: { $0.role == .user })?.content ?? "")
        return AsyncThrowingStream { continuation in
            let task = Task {
                let words = reply.split(separator: " ").map(String.init)
                for (index, word) in words.enumerated() {
                    try await Task.sleep(nanoseconds: 60_000_000)
                    let delta = index == 0 ? word : " " + word
                    continuation.yield(ProviderStreamChunk(deltaText: delta))
                }
                let usage = TokenUsage(
                    inputTokens: turns.reduce(0) { $0 + $1.content.split(separator: " ").count },
                    outputTokens: words.count
                )
                continuation.yield(ProviderStreamChunk(
                    deltaText: "",
                    isFinal: true,
                    usage: usage,
                    latencyMS: words.count * 60
                ))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
