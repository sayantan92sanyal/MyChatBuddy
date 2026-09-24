import Foundation

/// Hand-rolled client for the OpenAI Chat Completions streaming endpoint. Requests
/// `stream_options.include_usage` so the final SSE frame carries token usage —
/// otherwise OpenAI's streaming responses omit it entirely.
public struct OpenAIProvider: LLMProvider, Sendable {
    public static let apiKeyAccount = "openai-api-key"

    public let id: ProviderID = .openAI

    private let keychain: KeychainStore
    private let sseClient: SSEClient
    private let session: URLSession
    private let baseURL: URL

    public init(
        keychain: KeychainStore = KeychainStore(),
        sseClient: SSEClient = SSEClient(),
        session: URLSession = .shared,
        baseURL: URL = URL(string: "https://api.openai.com/v1/chat/completions")!
    ) {
        self.keychain = keychain
        self.sseClient = sseClient
        self.session = session
        self.baseURL = baseURL
    }

    public func isConfigured() async -> Bool {
        let key = (try? keychain.value(forAccount: Self.apiKeyAccount)) ?? nil
        return !(key ?? "").isEmpty
    }

    public func streamCompletion(
        model: ProviderModelDescriptor,
        systemPrompt: String?,
        turns: [ChatTurn],
        maxOutputTokens: Int
    ) -> AsyncThrowingStream<ProviderStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let apiKey = (try? keychain.value(forAccount: Self.apiKeyAccount)) ?? nil,
                          !apiKey.isEmpty else {
                        throw ProviderError.missingAPIKey
                    }

                    var request = URLRequest(url: baseURL)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

                    var messages: [OpenAIMessage] = []
                    if let systemPrompt, !systemPrompt.isEmpty {
                        messages.append(OpenAIMessage(role: "system", content: systemPrompt))
                    }
                    messages.append(contentsOf: turns.filter { $0.role != .system }.map {
                        OpenAIMessage(role: $0.role.rawValue, content: $0.content)
                    })

                    let body = OpenAIRequestBody(
                        model: model.id,
                        messages: messages,
                        stream: true,
                        streamOptions: .init(includeUsage: true),
                        maxTokens: maxOutputTokens
                    )
                    request.httpBody = try JSONEncoder().encode(body)

                    let start = Date()
                    var inputTokens = 0
                    var outputTokens = 0

                    for try await event in sseClient.events(for: request, session: session) {
                        if event.data == "[DONE]" { break }
                        guard let jsonData = event.data.data(using: .utf8) else { continue }
                        guard let decoded = try? JSONDecoder().decode(OpenAIStreamChunk.self, from: jsonData) else {
                            continue
                        }

                        if let delta = decoded.choices?.first?.delta?.content, !delta.isEmpty {
                            continuation.yield(ProviderStreamChunk(deltaText: delta))
                        }
                        if let usage = decoded.usage {
                            inputTokens = usage.promptTokens ?? inputTokens
                            outputTokens = usage.completionTokens ?? outputTokens
                        }
                        if let error = decoded.error {
                            throw ProviderError.network(error.message ?? "OpenAI API error")
                        }
                    }

                    let latencyMS = Int(Date().timeIntervalSince(start) * 1000)
                    continuation.yield(ProviderStreamChunk(
                        deltaText: "",
                        isFinal: true,
                        usage: TokenUsage(inputTokens: inputTokens, outputTokens: outputTokens),
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

private struct OpenAIMessage: Codable {
    let role: String
    let content: String
}

private struct OpenAIRequestBody: Codable {
    let model: String
    let messages: [OpenAIMessage]
    let stream: Bool
    let streamOptions: StreamOptions
    let maxTokens: Int

    struct StreamOptions: Codable {
        let includeUsage: Bool

        enum CodingKeys: String, CodingKey {
            case includeUsage = "include_usage"
        }
    }

    enum CodingKeys: String, CodingKey {
        case model, messages, stream
        case streamOptions = "stream_options"
        case maxTokens = "max_tokens"
    }
}

private struct OpenAIStreamChunk: Codable {
    let choices: [Choice]?
    let usage: Usage?
    let error: APIError?

    struct Choice: Codable {
        let delta: Delta?
    }

    struct Delta: Codable {
        let content: String?
    }

    struct Usage: Codable {
        let promptTokens: Int?
        let completionTokens: Int?

        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
        }
    }

    struct APIError: Codable {
        let message: String?
    }
}
