import Foundation
import Observation
import AIChatRouterKit

@Observable
@MainActor
final class ConversationListViewModel {
    private(set) var conversations: [Conversation] = []
    var selectedConversationID: UUID?

    private let conversationStore: ConversationStore

    init(conversationStore: ConversationStore) {
        self.conversationStore = conversationStore
    }

    func loadConversations() async {
        do {
            conversations = try await conversationStore.fetchAll()
            if selectedConversationID == nil {
                selectedConversationID = conversations.first?.id
            }
        } catch {
            conversations = []
        }
    }

    @discardableResult
    func createConversation() async -> Conversation? {
        let conversation = Conversation(title: "New Conversation")
        do {
            try await conversationStore.create(conversation)
            conversations.insert(conversation, at: 0)
            selectedConversationID = conversation.id
            return conversation
        } catch {
            return nil
        }
    }
}
