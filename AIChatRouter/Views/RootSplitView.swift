import SwiftUI
import AIChatRouterKit

struct RootSplitView: View {
    let environment: AppEnvironment
    @State private var listViewModel: ConversationListViewModel

    init(environment: AppEnvironment) {
        self.environment = environment
        _listViewModel = State(initialValue: ConversationListViewModel(
            conversationStore: environment.conversationStore
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            if !environment.networkStatusMonitor.isOnline {
                offlineBanner
            }

            NavigationSplitView {
                ConversationListView(viewModel: listViewModel)
            } detail: {
                if let selectedID = listViewModel.selectedConversationID,
                   let conversation = listViewModel.conversations.first(where: { $0.id == selectedID }) {
                    ChatView(conversation: conversation, environment: environment)
                        .id(conversation.id)
                } else {
                    ContentUnavailableView(
                        "No Conversation Selected",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("Create a new conversation to get started.")
                    )
                }
            }
        }
        .task {
            await listViewModel.loadConversations()
        }
    }

    private var offlineBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "wifi.slash")
            Text("You're offline — all responses will use the local model.")
                .font(.caption)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.25))
    }
}
