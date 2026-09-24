import SwiftUI
import AIChatRouterKit

struct ConversationListView: View {
    @Bindable var viewModel: ConversationListViewModel

    var body: some View {
        Group {
            if viewModel.conversations.isEmpty {
                ContentUnavailableView(
                    "No Conversations Yet",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Press ⌘N or use the button above to start one.")
                )
            } else {
                List(viewModel.conversations, selection: $viewModel.selectedConversationID) { conversation in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(conversation.title)
                            .font(.body)
                        Text("\(conversation.tokenTotalInput + conversation.tokenTotalOutput) tokens")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(conversation.id)
                }
            }
        }
        .navigationTitle("Conversations")
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await viewModel.createConversation() }
                } label: {
                    Label("New Conversation", systemImage: "square.and.pencil")
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }
    }
}
