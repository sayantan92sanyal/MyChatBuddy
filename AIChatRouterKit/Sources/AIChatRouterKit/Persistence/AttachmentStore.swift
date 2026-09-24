import Foundation
import GRDB

public struct AttachmentStore: Sendable {
    /// Default combined character budget across every attachment in one
    /// conversation — generous enough for real documents while staying
    /// comfortably inside any current cloud model's context window alongside
    /// real conversation history. User-configurable via
    /// `AppSettingsStore.loadAttachmentSizeCapCharacters()`; this is the fallback
    /// when no override has been saved.
    public static let defaultCharacterLimit = 50_000

    private let dbQueue: DatabaseQueue

    public init(database: AppDatabase) {
        self.dbQueue = database.dbQueue
    }

    public func append(_ attachment: Attachment) async throws {
        try await dbQueue.write { db in try attachment.insert(db) }
    }

    public func attachments(for conversationID: UUID) async throws -> [Attachment] {
        try await dbQueue.read { db in
            try Attachment
                .filter(Column("conversationID") == conversationID)
                .order(Column("createdAt"))
                .fetchAll(db)
        }
    }

    public func delete(id: UUID) async throws {
        _ = try await dbQueue.write { db in try Attachment.deleteOne(db, key: id) }
    }

    /// Pure helper so the combined-size math (existing attachments' total plus a
    /// candidate new one) can be verified without a database — this two-step
    /// arithmetic, not the storage itself, is the part most likely to have an
    /// off-by-one bug.
    public static func combinedLength(of attachments: [Attachment]) -> Int {
        attachments.reduce(0) { $0 + $1.extractedText.count }
    }

    /// The actual cap-boundary decision, kept here (not inline in `ChatViewModel`,
    /// which has no automated test target in this app) so the off-by-one — landing
    /// exactly on the limit must NOT count as exceeding it — is verified by a test.
    /// `limit` defaults to `defaultCharacterLimit` but callers pass the
    /// user-configured value from `AppSettingsStore` when one has been saved.
    public static func wouldExceedLimit(existing: [Attachment], addingLength: Int, limit: Int = defaultCharacterLimit) -> Bool {
        combinedLength(of: existing) + addingLength > limit
    }
}
