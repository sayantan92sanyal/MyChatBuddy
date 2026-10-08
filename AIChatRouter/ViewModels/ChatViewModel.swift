import Foundation
import CoreImage
import Observation
import UniformTypeIdentifiers
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
    private(set) var pendingImage: Data?
    private(set) var pendingImageFilename: String?
    private(set) var imageAttachmentsByMessageID: [UUID: ImageAttachment] = [:]

    private let conversationStore: ConversationStore
    private let messageStore: MessageStore
    private let routingCoordinator: RoutingCoordinator
    private let providerRegistry: ProviderRegistry
    private let usageLimiter: UsageLimiter
    private let settingsStore: AppSettingsStore
    private let attachmentStore: AttachmentStore
    private let imageAttachmentStore: ImageAttachmentStore

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
        attachmentStore: AttachmentStore,
        imageAttachmentStore: ImageAttachmentStore
    ) {
        self.conversation = conversation
        self.conversationStore = conversationStore
        self.messageStore = messageStore
        self.routingCoordinator = routingCoordinator
        self.providerRegistry = providerRegistry
        self.usageLimiter = usageLimiter
        self.settingsStore = settingsStore
        self.attachmentStore = attachmentStore
        self.imageAttachmentStore = imageAttachmentStore
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

    func loadImageAttachments() async {
        do {
            let images = try await imageAttachmentStore.images(for: conversation.id)
            imageAttachmentsByMessageID = Dictionary(images.map { ($0.messageID, $0) }, uniquingKeysWith: { _, newer in newer })
        } catch {
            attachmentError = "Failed to load images: \(error.localizedDescription)"
        }
    }

    /// `extraImagesIgnored` lets the caller (the composer's multi-select/drop
    /// handler) report that more than one image file was picked in a single
    /// action — only the first is ever kept as pending, but the rest must be
    /// surfaced, never silently dropped.
    func attachPendingImage(fileURL: URL, extraImagesIgnored: Int = 0) async {
        guard !isStreaming else {
            attachmentError = "Wait for the current response to finish before attaching an image."
            return
        }
        attachmentError = nil

        let sizeCap = settingsStore.loadImageAttachmentSizeCapBytes()
        let name = fileURL.lastPathComponent
        // Read, decode and downscale off the main actor — a large photo would
        // otherwise freeze the UI for the duration.
        let prepared = await Task.detached { Self.prepareImage(fileURL: fileURL, sizeCap: sizeCap) }.value

        let downscaled: Data
        switch prepared {
        case .ready(let data):
            downscaled = data
        case .unreadable:
            attachmentError = "\(name): couldn't read this file."
            return
        case .tooLarge(let bytes):
            attachmentError = "\(name) is \(bytes) bytes, over the \(sizeCap)-byte limit for image attachments."
            return
        case .notAnImage:
            attachmentError = "\(name): couldn't read this as an image."
            return
        }

        let replacedFilename = pendingImage != nil ? pendingImageFilename : nil
        pendingImage = downscaled
        pendingImageFilename = name

        if extraImagesIgnored > 0 {
            attachmentError = "Only one image can be attached per message — using \(name); ignored \(extraImagesIgnored) other image file(s) from the same selection."
        } else if let replacedFilename {
            attachmentError = "Replaced the previously attached image (\(replacedFilename)) with \(name)."
        }
    }

    private enum PreparedImage: Sendable {
        case ready(Data)
        case unreadable
        case tooLarge(Int)
        case notAnImage
    }

    /// Checks the file size from metadata first so an oversized file is never read
    /// into memory, then confirms the result decodes the same way the vision
    /// provider will (CIImage) so unsupported types fail here, not at send time.
    nonisolated private static func prepareImage(fileURL: URL, sizeCap: Int) -> PreparedImage {
        if let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.size] as? Int, size > sizeCap {
            return .tooLarge(size)
        }
        guard let data = try? Data(contentsOf: fileURL) else { return .unreadable }
        guard data.count <= sizeCap else { return .tooLarge(data.count) }
        guard let downscaled = ImageDownscaler().downscale(data), CIImage(data: downscaled) != nil else {
            return .notAnImage
        }
        return .ready(downscaled)
    }

    func removePendingImage() {
        pendingImage = nil
        pendingImageFilename = nil
    }

    static func isImageFile(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image)
    }

    func addAttachment(fileURL: URL) async {
        guard !isStreaming else {
            attachmentError = "Wait for the current response to finish before attaching files."
            return
        }
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

        let sizeCap = settingsStore.loadAttachmentSizeCapCharacters()
        guard !AttachmentStore.wouldExceedLimit(existing: attachments, addingLength: extractedText.count, limit: sizeCap) else {
            let wouldBeTotal = AttachmentStore.combinedLength(of: attachments) + extractedText.count
            attachmentError = "\(fileURL.lastPathComponent) would push attachments to \(wouldBeTotal) characters, over the \(sizeCap)-character limit for this conversation."
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
        var text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        // An image with no typed question is a valid message: ask for a description.
        if text.isEmpty, pendingImage != nil { text = "Describe this image." }
        guard !text.isEmpty, !isStreaming else { return }
        draftText = ""
        errorMessage = nil
        routingNote = nil
        usageWarning = nil
        pendingSearchPermission = false
        pendingSend = nil

        let imageForThisSend = pendingImage
        let imageFilenameForThisSend = pendingImageFilename ?? "image"
        pendingImage = nil
        pendingImageFilename = nil

        // A follow-up in a conversation that already has an image stays on the
        // vision slot and re-attaches the most recent image: the text models can't
        // see it, and history turns carry only text.
        let reusedImage = imageForThisSend == nil ? mostRecentConversationImage() : nil

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

        if let imageData = imageForThisSend ?? reusedImage?.imageData {
            if reusedImage != nil {
                routingNote = "Using the vision model because this conversation includes an image."
            }
            await sendWithVisionSlot(
                userMessage: userMessage,
                imageData: imageData,
                imageFilename: imageFilenameForThisSend,
                persistImage: reusedImage == nil
            )
            return
        }

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

    /// Deliberately bypasses `RoutingCoordinator`: an attached image always goes to
    /// the local vision slot regardless of tier, usage caps, the search toggle, or
    /// offline state — local inference is free and on-device, so none of that
    /// machinery applies. No routing-log entry is written for this turn either.
    private func mostRecentConversationImage() -> ImageAttachment? {
        messages.reversed().lazy.compactMap { self.imageAttachmentsByMessageID[$0.id] }.first
    }

    private func sendWithVisionSlot(userMessage: Message, imageData: Data, imageFilename: String, persistImage: Bool) async {
        guard await providerRegistry.isLocalModelReady(kind: .vision) else {
            errorMessage = "The vision model isn't downloaded yet. Download it in Settings → Local Model, then attach the image again."
            isStreaming = false
            streamingText = ""
            return
        }

        var turns = messages.map {
            ChatTurn(role: ChatTurn.Role(rawValue: $0.role.rawValue) ?? .user, content: $0.content)
        }
        if let lastIndex = turns.indices.last {
            let last = turns[lastIndex]
            turns[lastIndex] = ChatTurn(role: last.role, content: last.content, images: [imageData])
        }

        let (provider, descriptor) = providerRegistry.resolveVision()
        await performSend(
            provider: provider,
            modelDescriptor: descriptor,
            turns: turns,
            enableWebSearch: false
        )

        if persistImage, errorMessage != nil {
            errorMessage = (errorMessage ?? "") + " The image wasn't sent — attach it again to retry."
        }

        guard persistImage, errorMessage == nil, let lastMessage = messages.last, lastMessage.role == .assistant else {
            return
        }

        let imageAttachment = ImageAttachment(
            conversationID: conversation.id,
            messageID: userMessage.id,
            filename: imageFilename,
            imageData: imageData,
            sizeBytes: imageData.count
        )
        do {
            try await imageAttachmentStore.append(imageAttachment)
            imageAttachmentsByMessageID[userMessage.id] = imageAttachment
        } catch {
            attachmentError = "Sent, but failed to save the image for history: \(error.localizedDescription)"
        }
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
        if modelDescriptor.providerID != .localMLX, modelDescriptor.providerID != .localVLM, await !provider.isConfigured() {
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
