import SwiftUI
import AIChatRouterKit

struct ChatView: View {
    @State private var viewModel: ChatViewModel
    @State private var webSearchEnabled: Bool
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

            Divider()

            MessageComposerView(
                text: $viewModel.draftText,
                isSending: viewModel.isStreaming,
                onSend: { Task { await viewModel.sendMessage() } }
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
        .task {
            await viewModel.loadMessages()
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
}
