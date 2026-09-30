import Foundation
import Testing
@testable import AIChatRouterKit

@Suite("ImageAttachmentStore")
struct ImageAttachmentStoreTests {
    @Test func appendFetchAndDeleteRoundTrip() async throws {
        let db = try AppDatabase.openInMemory()
        let conversations = ConversationStore(database: db)
        let messages = MessageStore(database: db)
        let images = ImageAttachmentStore(database: db)

        let conversation = Conversation(title: "Image Test")
        try await conversations.create(conversation)
        let message = Message(conversationID: conversation.id, role: .user, content: "what's in this photo?")
        try await messages.append(message)

        let image = ImageAttachment(
            conversationID: conversation.id,
            messageID: message.id,
            filename: "photo.png",
            imageData: Data([0x01, 0x02, 0x03]),
            sizeBytes: 3
        )
        try await images.append(image)

        let fetched = try await images.images(for: conversation.id)
        #expect(fetched.count == 1)
        #expect(fetched.first?.filename == "photo.png")
        #expect(fetched.first?.messageID == message.id)
        #expect(fetched.first?.imageData == Data([0x01, 0x02, 0x03]))

        try await images.delete(id: image.id)
        let afterDelete = try await images.images(for: conversation.id)
        #expect(afterDelete.isEmpty)
    }

    @Test func deletingConversationCascadesImageAttachments() async throws {
        let db = try AppDatabase.openInMemory()
        let conversations = ConversationStore(database: db)
        let messages = MessageStore(database: db)
        let images = ImageAttachmentStore(database: db)

        let conversation = Conversation(title: "To Delete")
        try await conversations.create(conversation)
        let message = Message(conversationID: conversation.id, role: .user, content: "hi")
        try await messages.append(message)
        try await images.append(ImageAttachment(
            conversationID: conversation.id,
            messageID: message.id,
            filename: "a.png",
            imageData: Data([0x00]),
            sizeBytes: 1
        ))

        try await conversations.delete(id: conversation.id)

        let remaining = try await images.images(for: conversation.id)
        #expect(remaining.isEmpty)
    }
}
