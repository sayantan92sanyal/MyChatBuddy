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
    private(set) var pendingSearchPermission = false
    private(set) var attachments: [Attachment] = []
    private(set) var attachmentError: String?

    private let conversationStore: ConversationStore
    private let messageStore: MessageStore
    private let routingCoordinator: RoutingCoordinator
    private let providerRegistry: ProviderRegistry
    private let usageLimiter: UsageLimiter
    private let settingsStore: AppSettingsStore
    private let attachmentStore: AttachmentStore

    private struct PendingSend {
        let turns: [ChatTurn]
    }
    private var pendingSend: PendingSend?

    private var attachmentsSystemPrompt: String? {
        guard !attachments.isEmpty else { return nil }
        let sections = attachments.map { "--- \($0.filename) ---\n\($0.extractedText)" }
        return "The user has attached the following file(s) — use their content to answer questions about them:\n\n"
            + sections.joined(separator: "\n\n")
    }

    init(
        conversation: Conversation,
        conversationStore: ConversationStore,
        messageStore: MessageStore,
        routingCoordinator: RoutingCoordinator,
        providerRegistry: ProviderRegistry,
        usageLimiter: UsageLimiter,
        settingsStore: AppSettingsStore,
        attachmentStore: AttachmentStore
    ) {
        self.conversation = conversation
        self.conversationStore = conversationStore
        self.messageStore = messageStore
        self.routingCoordinator = routingCoordinator
        self.providerRegistry = providerRegistry
        self.usageLimiter = usageLimiter
        self.settingsStore = settingsStore
        self.attachmentStore = attachmentStore
    }

    func loadMessages() async {
        do {
            messages = try await messageStore.messages(for: conversation.id)
        } catch {
            errorMessage = "Failed to load messages: \(error.localizedDescription)"
        }
    }

    func loadAttachments() async {
        do {
            attachments = try await attachmentStore.attachments(for: conversation.id)
        } catch {
            attachmentError = "Failed to load attachments: \(error.localizedDescription)"
        }
    }

    func addAttachment(fileURL: URL) async {
        guard !isStreaming else { return }
        attachmentError = nil

        let extractedText: String
        do {
            extractedText = try await FileTextExtractor().extractText(from: fileURL)
        } catch AttachmentError.unreadableAsText {
            attachmentError = "\(fileURL.lastPathComponent): couldn't read this as text."
            return
        } catch AttachmentError.extractionFailed(let reason) {
            attachmentError = "\(fileURL.lastPathComponent): \(reason)"
            return
        } catch {
            attachmentError = "\(fileURL.lastPathComponent): \(error.localizedDescription)"
            return
        }

        guard !AttachmentStore.wouldExceedLimit(existing: attachments, addingLength: extractedText.count) else {
            let wouldBeTotal = AttachmentStore.combinedLength(of: attachments) + extractedText.count
            attachmentError = "\(fileURL.lastPathComponent) would push attachments to \(wouldBeTotal) characters, over the \(AttachmentStore.combinedCharacterLimit)-character limit for this conversation."
            return
        }

        let sizeBytes: Int
        if let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           let fileSize = attributes[.size] as? Int {
            sizeBytes = fileSize
        } else {
            sizeBytes = extractedText.utf8.count
        }

        let attachment = Attachment(
            conversationID: conversation.id,
            filename: fileURL.lastPathComponent,
            fileType: fileURL.pathExtension,
            extractedText: extractedText,
            sizeBytes: sizeBytes
        )

        do {
            try await attachmentStore.append(attachment)
            attachments.append(attachment)
        } catch {
            attachmentError = "Failed to save \(fileURL.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func removeAttachment(_ id: UUID) async {
        do {
            try await attachmentStore.delete(id: id)
            attachments.removeAll { $0.id == id }
        } catch {
            attachmentError = "Failed to remove attachment: \(error.localizedDescription)"
        }
    }

    func sendMessage() async {
        let text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }
        draftText = ""
        errorMessage = nil
        routingNote = nil
        usageWarning = nil
        pendingSearchPermission = false
        pendingSend = nil

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

        if let downgradeReason = decision.downgradeReason {
            routingNote = downgradeReason
        }

        let turns = messages.map {
            ChatTurn(role: ChatTurn.Role(rawValue: $0.role.rawValue) ?? .user, content: $0.content)
        }

        // Only offer the permission banner if the override tier's provider can
        // actually search — otherwise Allow would spend a cloud call that can't
        // deliver what the banner promised.
        if decision.requiresSearchPermission, let overrideTier = decision.searchOverrideTier,
           let overrideResolved = providerRegistry.resolve(tier: overrideTier),
           overrideResolved.provider.supportsWebSearch {
            pendingSend = PendingSend(turns: turns)
            pendingSearchPermission = true
            isStreaming = false
            streamingText = ""
            return
        }

        guard let resolved = providerRegistry.resolve(tier: decision.tier) else {
            errorMessage = "No provider is configured for the \(decision.tier) tier."
            isStreaming = false
            streamingText = ""
            return
        }

        var enableWebSearch = decision.needsWebSearch && decision.tier != .local
        if enableWebSearch, !resolved.provider.supportsWebSearch {
            // The tier's configured provider can't search (e.g. cloudFast mapped
            // to a provider without search wiring yet) — proceed without search
            // rather than silently pretending it happened, but say so.
            enableWebSearch = false
            routingNote = routingNote ?? "\(resolved.descriptor.displayName) can't search yet — answering without live search."
        }
        await performSend(
            provider: resolved.provider,
            modelDescriptor: resolved.descriptor,
            turns: turns,
            enableWebSearch: enableWebSearch
        )
    }

    func allowSearchOverride() async {
        guard let pending = pendingSend else { return }
        pendingSearchPermission = false
        pendingSend = nil

        // Re-read the toggle rather than trusting that it's still on: it could
        // have been switched off in the moment between the banner appearing and
        // the user clicking Allow, and Allow must never enable search once the
        // toggle says not to — that's the whole point of the toggle.
        guard settingsStore.loadWebSearchEnabled() else {
            await denySearchOverrideWithoutConsumingPending(turns: pending.turns)
            return
        }

        guard let resolved = providerRegistry.resolve(tier: .cloudFast) else {
            errorMessage = "No provider is configured for the cloudFast tier."
            return
        }

        // Defensive re-check: the tier mapping could have changed to a
        // non-search provider between the banner appearing and this click.
        guard resolved.provider.supportsWebSearch else {
            await denySearchOverrideWithoutConsumingPending(turns: pending.turns)
            return
        }

        isStreaming = true
        streamingText = ""
        await performSend(
            provider: resolved.provider,
            modelDescriptor: resolved.descriptor,
            turns: pending.turns,
            enableWebSearch: true
        )
    }

    func denySearchOverride() async {
        guard let pending = pendingSend else { return }
        pendingSearchPermission = false
        pendingSend = nil
        await denySearchOverrideWithoutConsumingPending(turns: pending.turns)
    }

    /// Shared by `denySearchOverride()` and `allowSearchOverride()`'s toggle-off
    /// fallback — both send via the local tier with search disabled once the
    /// caller has already cleared `pendingSend`/`pendingSearchPermission` itself.
    private func denySearchOverrideWithoutConsumingPending(turns: [ChatTurn]) async {
        guard let resolved = providerRegistry.resolve(tier: .local) else {
            errorMessage = "No provider is configured for the local tier."
            return
        }

        isStreaming = true
        streamingText = ""
        await performSend(
            provider: resolved.provider,
            modelDescriptor: resolved.descriptor,
            turns: turns,
            enableWebSearch: false
        )
    }

    private func performSend(
        provider: LLMProvider,
        modelDescriptor: ProviderModelDescriptor,
        turns: [ChatTurn],
        enableWebSearch: Bool
    ) async {
        if modelDescriptor.providerID != .localMLX, await !provider.isConfigured() {
            errorMessage = "\(modelDescriptor.displayName) needs an API key. Add one in Settings before sending."
            isStreaming = false
            streamingText = ""
            return
        }

        do {
            var finalUsage: TokenUsage?
            var finalLatency: Int?
            var finalCitations: [SearchCitation]?
            let stream = provider.streamCompletion(
                model: modelDescriptor,
                systemPrompt: attachmentsSystemPrompt,
                turns: turns,
                maxOutputTokens: 1024,
                enableWebSearch: enableWebSearch
            )
            for try await chunk in stream {
                if !chunk.deltaText.isEmpty {
                    streamingText += chunk.deltaText
                }
                if chunk.isFinal {
                    finalUsage = chunk.usage
                    finalLatency = chunk.latencyMS
                    finalCitations = chunk.citations
                }
            }

            // A stream that ends without throwing but produced no text (e.g. a
            // provider-side tool/search failure surfaced as a quiet empty
            // response rather than a thrown error) must not be saved as a blank
            // assistant message — that's indistinguishable from a real answer in
            // the transcript and leaves the user with no idea anything went wrong.
            guard !streamingText.isEmpty else {
                errorMessage = "Response failed: the model returned an empty reply."
                isStreaming = false
                streamingText = ""
                return
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
                latencyMS: finalLatency,
                citationsJSON: Message.encodeCitations(finalCitations)
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
