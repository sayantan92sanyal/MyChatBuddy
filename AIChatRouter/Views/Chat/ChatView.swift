import SwiftUI
import UniformTypeIdentifiers
import AIChatRouterKit

struct ChatView: View {
    @State private var viewModel: ChatViewModel
    @State private var webSearchEnabled: Bool
    @State private var showingFileImporter = false
    private let conversationTitle: String
    private let displayName: (String) -> String
    private let settingsStore: AppSettingsStore

    init(conversation: Conversation, environment: AppEnvironment) {
        self.conversationTitle = conversation.title
        self.displayName = environment.displayName(forModelID:)
        self.settingsStore = environment.settingsStore
        _webSearchEnabled = State(initialValue: environment.settingsStore.loadWebSearchEnabled())
        _viewModel = State(initialValue: ChatViewModel(
            conversation: conversation,
            conversationStore: environment.conversationStore,
            messageStore: environment.messageStore,
            routingCoordinator: environment.routingCoordinator,
            providerRegistry: environment.providerRegistry,
            usageLimiter: environment.usageLimiter,
            settingsStore: environment.settingsStore,
            attachmentStore: environment.attachmentStore
        ))
    }

    private var attachmentContentTypes: [UTType] {
        var types: [UTType] = [.plainText, .pdf, .sourceCode, .text]
        if let docx = UTType(filenameExtension: "docx") { types.append(docx) }
        return types
    }

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.messages.isEmpty && !viewModel.isStreaming {
                ContentUnavailableView(
                    "Start the Conversation",
                    systemImage: "text.bubble",
                    description: Text("Type a message below — it'll be routed automatically to the local model or a cloud tier based on complexity.")
                )
                .frame(maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(viewModel.messages) { message in
                                MessageBubbleView(message: message, displayName: displayName)
                                    .id(message.id)
                            }
                            if viewModel.isStreaming {
                                HStack {
                                    Text(viewModel.streamingText)
                                        .padding(10)
                                        .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                                    Spacer(minLength: 40)
                                }
                                .id("streaming")
                            }
                        }
                        .padding()
                    }
                    .onChange(of: viewModel.messages.count) {
                        scrollToBottom(proxy: proxy)
                    }
                    .onChange(of: viewModel.streamingText) {
                        scrollToBottom(proxy: proxy)
                    }
                }
            }

            if !viewModel.attachments.isEmpty {
                attachmentChips
            }

            if viewModel.pendingSearchPermission {
                searchPermissionBanner
            }

            if let routingNote = viewModel.routingNote {
                Text(routingNote)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal)
            }

            if let usageWarning = viewModel.usageWarning {
                Text(usageWarning)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }

            if let attachmentError = viewModel.attachmentError {
                Text(attachmentError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }

            Divider()

            MessageComposerView(
                text: $viewModel.draftText,
                isSending: viewModel.isStreaming,
                onSend: { Task { await viewModel.sendMessage() } },
                onAttach: { showingFileImporter = true }
            )
        }
        .navigationTitle(conversationTitle)
        .toolbar {
            ToolbarItem {
                Button {
                    webSearchEnabled.toggle()
                    settingsStore.saveWebSearchEnabled(webSearchEnabled)
                } label: {
                    Image(systemName: webSearchEnabled ? "globe" : "globe.desk.fill")
                }
                .help(webSearchEnabled ? "Web search: On" : "Web search: Off")
            }
        }
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: attachmentContentTypes,
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result else { return }
            // Attach sequentially, not as separate concurrent Tasks: addAttachment
            // checks the combined size cap against `attachments` synchronously at
            // the start of its own call, so two files attached concurrently could
            // both pass the check before either is appended, bypassing the cap
            // multi-select is explicitly meant to be checked against.
            Task {
                for url in urls {
                    let didAccess = url.startAccessingSecurityScopedResource()
                    await viewModel.addAttachment(fileURL: url)
                    if didAccess { url.stopAccessingSecurityScopedResource() }
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            // Same sequential-attach reasoning as the file importer above: resolve
            // every dropped provider's URL first (fine to do concurrently, it's
            // just reading the URL), then attach them one at a time so the size
            // cap sees each prior file in the same drop before checking the next.
            Task {
                var urls: [URL] = []
                for provider in providers {
                    if let url = await resolveFileURL(from: provider) {
                        urls.append(url)
                    }
                }
                for url in urls {
                    await viewModel.addAttachment(fileURL: url)
                }
            }
            return true
        }
        .task {
            await viewModel.loadMessages()
            await viewModel.loadAttachments()
        }
    }

    private var attachmentChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(viewModel.attachments) { attachment in
                    HStack(spacing: 4) {
                        Image(systemName: "doc.text")
                        Text(attachment.filename)
                            .font(.caption)
                            .lineLimit(1)
                        Button {
                            Task { await viewModel.removeAttachment(attachment.id) }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
                }
            }
            .padding(.horizontal)
            .padding(.top, 6)
        }
    }

    private var searchPermissionBanner: some View {
        HStack {
            Text("This needs web search but you're over budget — allow this one cloud call anyway?")
                .font(.caption)
            Spacer()
            Button("Deny") { Task { await viewModel.denySearchOverride() } }
                .buttonStyle(.plain)
            Button("Allow") { Task { await viewModel.allowSearchOverride() } }
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.15))
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        withAnimation {
            if viewModel.isStreaming {
                proxy.scrollTo("streaming", anchor: .bottom)
            } else if let lastID = viewModel.messages.last?.id {
                proxy.scrollTo(lastID, anchor: .bottom)
            }
        }
    }

    private func resolveFileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url)
            }
        }
    }
}
