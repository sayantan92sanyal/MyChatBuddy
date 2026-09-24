import Foundation
import Observation
import AIChatRouterKit

@Observable
@MainActor
final class ChatViewModel {
    private(set) var conversation: Conversation
    private(set) var messages: [Message] = []
    var draftText: String = ""
    private(set) var isStreaming = false
    private(set) var streamingText = ""
    private(set) var errorMessage: String?
    private(set) var routingNote: String?
    private(set) var usageWarning: String?

    private let conversationStore: ConversationStore
    private let messageStore: MessageStore
    private let routingCoordinator: RoutingCoordinator
    private let providerRegistry: ProviderRegistry
    private let usageLimiter: UsageLimiter
    private let settingsStore: AppSettingsStore

    init(
        conversation: Conversation,
        conversationStore: ConversationStore,
        messageStore: MessageStore,
        routingCoordinator: RoutingCoordinator,
        providerRegistry: ProviderRegistry,
        usageLimiter: UsageLimiter,
        settingsStore: AppSettingsStore
    ) {
        self.conversation = conversation
        self.conversationStore = conversationStore
        self.messageStore = messageStore
        self.routingCoordinator = routingCoordinator
        self.providerRegistry = providerRegistry
        self.usageLimiter = usageLimiter
        self.settingsStore = settingsStore
    }

    func loadMessages() async {
        do {
            messages = try await messageStore.messages(for: conversation.id)
        } catch {
            errorMessage = "Failed to load messages: \(error.localizedDescription)"
        }
    }

    func sendMessage() async {
        let text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }
        draftText = ""
        errorMessage = nil
        routingNote = nil
        usageWarning = nil

        let userMessage = Message(conversationID: conversation.id, role: .user, content: text)
        do {
            try await messageStore.append(userMessage)
        } catch {
            errorMessage = "Failed to save message: \(error.localizedDescription)"
            return
        }
        messages.append(userMessage)

        isStreaming = true
        streamingText = ""

        let recentTurns = ContextWindowBuilder().build(from: Array(messages.dropLast()))
        let routingContext = RoutingContext(
            conversationID: conversation.id,
            recentTurns: recentTurns,
            candidateQuery: text,
            sensitivityBias: settingsStore.loadRoutingSensitivity()
        )
        let decision = await routingCoordinator.decide(routingContext)

        guard let resolved = providerRegistry.resolve(tier: decision.tier) else {
            errorMessage = "No provider is configured for the \(decision.tier) tier."
            isStreaming = false
            streamingText = ""
            return
        }
        let provider = resolved.provider
        let modelDescriptor = resolved.descriptor

        if let downgradeReason = decision.downgradeReason {
            routingNote = downgradeReason
        }

        if modelDescriptor.providerID != .localMLX, await !provider.isConfigured() {
            errorMessage = "\(modelDescriptor.displayName) needs an API key. Add one in Settings before sending."
            isStreaming = false
            streamingText = ""
            return
        }

        let turns = messages.map {
            ChatTurn(role: ChatTurn.Role(rawValue: $0.role.rawValue) ?? .user, content: $0.content)
        }

        do {
            var finalUsage: TokenUsage?
            var finalLatency: Int?
            let stream = provider.streamCompletion(
                model: modelDescriptor,
                systemPrompt: nil,
                turns: turns,
                maxOutputTokens: 1024
            )
            for try await chunk in stream {
                if !chunk.deltaText.isEmpty {
                    streamingText += chunk.deltaText
                }
                if chunk.isFinal {
                    finalUsage = chunk.usage
                    finalLatency = chunk.latencyMS
                }
            }

            let assistantMessage = Message(
                conversationID: conversation.id,
                role: .assistant,
                content: streamingText,
                providerID: provider.id,
                modelID: modelDescriptor.id,
                tier: modelDescriptor.tier,
                inputTokens: finalUsage?.inputTokens,
                outputTokens: finalUsage?.outputTokens,
                latencyMS: finalLatency
            )
            try await messageStore.append(assistantMessage)
            messages.append(assistantMessage)

            if let usage = finalUsage {
                try await conversationStore.addTokenUsage(
                    id: conversation.id,
                    input: usage.inputTokens,
                    output: usage.outputTokens
                )
                conversation.tokenTotalInput += usage.inputTokens
                conversation.tokenTotalOutput += usage.outputTokens

                await usageLimiter.recordUsage(
                    conversationID: conversation.id,
                    messageID: assistantMessage.id,
                    providerID: provider.id,
                    tier: modelDescriptor.tier,
                    modelID: modelDescriptor.id,
                    usage: usage
                )
                usageWarning = await usageLimiter.softCapWarning(for: conversation.id)
            }
        } catch ProviderError.missingAPIKey, ProviderError.invalidAPIKey {
            errorMessage = "\(modelDescriptor.displayName) needs a valid API key. Add one in Settings."
        } catch {
            errorMessage = "Response failed: \(error.localizedDescription)"
        }

        isStreaming = false
        streamingText = ""
    }
}
