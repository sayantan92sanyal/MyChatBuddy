import Foundation

/// Hand-rolled client for the Anthropic Messages API streaming endpoint. No official
/// Swift SDK exists, and per-call token usage (core IP, feeds the UsageLimiter) is
/// safer to own directly than to depend on an unofficial wrapper.
///
/// Web search support (`web_search_20250305` tool) was verified live against the real
/// API during v2 planning: search results arrive as a `web_search_tool_result` content
/// block (the full raw hit list — not surfaced to the user), and the sources the model
/// actually drew from arrive as `citations_delta` events attached to the text it
/// generates. This provider surfaces the latter (what was cited), not the former (every
/// raw hit), matching the spec's "Sources" list being what was actually used.
public struct AnthropicProvider: LLMProvider, Sendable {
    public static let apiKeyAccount = "anthropic-api-key"

    public let id: ProviderID = .anthropic

    private let keychain: KeychainStore
    private let sseClient: SSEClient
    private let session: URLSession
    private let baseURL: URL

    public init(
        keychain: KeychainStore = KeychainStore(),
        sseClient: SSEClient = SSEClient(),
        session: URLSession = .shared,
        baseURL: URL = URL(string: "https://api.anthropic.com/v1/messages")!
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
        maxOutputTokens: Int,
        enableWebSearch: Bool
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
                    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

                    let body = AnthropicRequestBody(
                        model: model.id,
                        maxTokens: maxOutputTokens,
                        system: systemPrompt,
                        stream: true,
                        messages: turns.filter { $0.role != .system }.map {
                            AnthropicMessage(role: $0.role == .user ? "user" : "assistant", content: $0.content)
                        },
                        tools: enableWebSearch
                            ? [AnthropicTool(type: "web_search_20250305", name: "web_search", maxUses: 5)]
                            : nil
                    )
                    request.httpBody = try JSONEncoder().encode(body)

                    let start = Date()
                    var inputTokens = 0
                    var outputTokens = 0
                    var citationsSeen: [String: SearchCitation] = [:]

                    for try await event in sseClient.events(for: request, session: session) {
                        guard let jsonData = event.data.data(using: .utf8) else { continue }
                        guard let decoded = try? JSONDecoder().decode(AnthropicStreamEvent.self, from: jsonData) else {
                            continue
                        }

                        switch decoded.type {
                        case "content_block_delta":
                            if let text = decoded.delta?.text, !text.isEmpty {
                                continuation.yield(ProviderStreamChunk(deltaText: text))
                            }
                            if let citation = decoded.delta?.citation, let url = citation.url {
                                citationsSeen[url] = SearchCitation(url: url, title: citation.title)
                            }
                        case "message_start":
                            if let usage = decoded.message?.usage {
                                inputTokens = usage.inputTokens ?? inputTokens
                            }
                        case "message_delta":
                            if let usage = decoded.usage {
                                outputTokens = usage.outputTokens ?? outputTokens
                                // With web search enabled, the results fed back to the
                                // model are billed as additional input tokens that only
                                // show up here — live-verified: message_start reported
                                // 2227 input tokens for a search query, message_delta's
                                // final usage reported 8807 once the search results were
                                // counted. message_start's count alone would have
                                // undercounted this call by roughly 74%.
                                inputTokens = usage.inputTokens ?? inputTokens
                            }
                        default:
                            break
                        }

                        if let error = decoded.error {
                            throw ProviderError.network(error.message ?? "Anthropic API error")
                        }
                    }

                    let latencyMS = Int(Date().timeIntervalSince(start) * 1000)
                    continuation.yield(ProviderStreamChunk(
                        deltaText: "",
                        isFinal: true,
                        usage: TokenUsage(inputTokens: inputTokens, outputTokens: outputTokens),
                        latencyMS: latencyMS,
                        citations: citationsSeen.isEmpty ? nil : Array(citationsSeen.values)
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

private struct AnthropicMessage: Codable {
    let role: String
    let content: String
}

private struct AnthropicTool: Codable {
    let type: String
    let name: String
    let maxUses: Int

    enum CodingKeys: String, CodingKey {
        case type, name
        case maxUses = "max_uses"
    }
}

private struct AnthropicRequestBody: Codable {
    let model: String
    let maxTokens: Int
    let system: String?
    let stream: Bool
    let messages: [AnthropicMessage]
    let tools: [AnthropicTool]?

    enum CodingKeys: String, CodingKey {
        case model, system, stream, messages, tools
        case maxTokens = "max_tokens"
    }
}

private struct AnthropicStreamEvent: Codable {
    let type: String?
    let delta: Delta?
    let message: MessageStart?
    let usage: Usage?
    let error: APIError?

    struct Delta: Codable {
        let text: String?
        let citation: Citation?
    }

    struct Citation: Codable {
        let url: String?
        let title: String?
    }

    struct MessageStart: Codable {
        let usage: Usage?
    }

    struct Usage: Codable {
        let inputTokens: Int?
        let outputTokens: Int?

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
        }
    }

    struct APIError: Codable {
        let message: String?
    }
}
