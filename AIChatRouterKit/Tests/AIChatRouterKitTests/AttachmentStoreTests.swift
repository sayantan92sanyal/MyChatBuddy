import Foundation
import Testing
@testable import AIChatRouterKit

@Suite("AttachmentStore")
struct AttachmentStoreTests {
    @Test func appendFetchAndDeleteRoundTrip() async throws {
        let db = try AppDatabase.openInMemory()
        let conversations = ConversationStore(database: db)
        let attachments = AttachmentStore(database: db)

        let conversation = Conversation(title: "Attachment Test")
        try await conversations.create(conversation)

        let attachment = Attachment(
            conversationID: conversation.id,
            filename: "notes.txt",
            fileType: "txt",
            extractedText: "Some extracted text",
            sizeBytes: 20
        )
        try await attachments.append(attachment)

        let fetched = try await attachments.attachments(for: conversation.id)
        #expect(fetched.count == 1)
        #expect(fetched.first?.filename == "notes.txt")
        #expect(fetched.first?.extractedText == "Some extracted text")

        try await attachments.delete(id: attachment.id)
        let afterDelete = try await attachments.attachments(for: conversation.id)
        #expect(afterDelete.isEmpty)
    }

    @Test func deletingConversationCascadesAttachments() async throws {
        let db = try AppDatabase.openInMemory()
        let conversations = ConversationStore(database: db)
        let attachments = AttachmentStore(database: db)

        let conversation = Conversation(title: "To Delete")
        try await conversations.create(conversation)
        try await attachments.append(Attachment(
            conversationID: conversation.id,
            filename: "a.txt",
            fileType: "txt",
            extractedText: "text",
            sizeBytes: 4
        ))

        try await conversations.delete(id: conversation.id)

        let remaining = try await attachments.attachments(for: conversation.id)
        #expect(remaining.isEmpty)
    }

    @Test func combinedLengthSumsExtractedTextAcrossAttachments() {
        let a = Attachment(conversationID: UUID(), filename: "a.txt", fileType: "txt", extractedText: "12345", sizeBytes: 5)
        let b = Attachment(conversationID: UUID(), filename: "b.txt", fileType: "txt", extractedText: "1234567890", sizeBytes: 10)
        #expect(AttachmentStore.combinedLength(of: [a, b]) == 15)
    }

    @Test func combinedLengthOfEmptyArrayIsZero() {
        #expect(AttachmentStore.combinedLength(of: []) == 0)
    }

    @Test func wouldExceedLimitIsFalseExactlyAtTheBoundary() {
        // Existing total + new length landing exactly on the cap must NOT count
        // as exceeding it — this is the off-by-one this helper exists to pin down.
        let existing = [Attachment(
            conversationID: UUID(), filename: "a.txt", fileType: "txt",
            extractedText: String(repeating: "x", count: AttachmentStore.defaultCharacterLimit - 100),
            sizeBytes: 0
        )]
        #expect(AttachmentStore.wouldExceedLimit(existing: existing, addingLength: 100) == false)
    }

    @Test func wouldExceedLimitIsTrueOneOverTheBoundary() {
        let existing = [Attachment(
            conversationID: UUID(), filename: "a.txt", fileType: "txt",
            extractedText: String(repeating: "x", count: AttachmentStore.defaultCharacterLimit - 100),
            sizeBytes: 0
        )]
        #expect(AttachmentStore.wouldExceedLimit(existing: existing, addingLength: 101) == true)
    }

    @Test func wouldExceedLimitIsFalseWellUnderTheCap() {
        #expect(AttachmentStore.wouldExceedLimit(existing: [], addingLength: 500) == false)
    }

    @Test func wouldExceedLimitRespectsACustomLimit() {
        // A caller (ChatViewModel, reading the user-configured cap from
        // AppSettingsStore) can pass a limit other than the built-in default.
        let existing = [Attachment(
            conversationID: UUID(), filename: "a.txt", fileType: "txt",
            extractedText: String(repeating: "x", count: 90),
            sizeBytes: 0
        )]
        #expect(AttachmentStore.wouldExceedLimit(existing: existing, addingLength: 5, limit: 100) == false)
        #expect(AttachmentStore.wouldExceedLimit(existing: existing, addingLength: 11, limit: 100) == true)
    }
}
