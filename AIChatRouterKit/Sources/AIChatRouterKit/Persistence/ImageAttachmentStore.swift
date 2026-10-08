import Foundation
import GRDB

public struct ImageAttachmentStore: Sendable {
    private let dbQueue: DatabaseQueue

    public init(database: AppDatabase) {
        self.dbQueue = database.dbQueue
    }

    public func append(_ image: ImageAttachment) async throws {
        try await dbQueue.write { db in try image.insert(db) }
    }

    public func images(for conversationID: UUID) async throws -> [ImageAttachment] {
        try await dbQueue.read { db in
            try ImageAttachment
                .filter(Column("conversationID") == conversationID)
                .order(Column("createdAt"))
                .fetchAll(db)
        }
    }

    public func delete(id: UUID) async throws {
        _ = try await dbQueue.write { db in try ImageAttachment.deleteOne(db, key: id) }
    }
}
