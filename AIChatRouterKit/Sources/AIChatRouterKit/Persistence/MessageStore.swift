import Foundation
import GRDB

public struct MessageStore: Sendable {
    private let dbQueue: DatabaseQueue

    public init(database: AppDatabase) {
        self.dbQueue = database.dbQueue
    }

    public func append(_ message: Message) async throws {
        try await dbQueue.write { db in try message.insert(db) }
    }

    public func update(_ message: Message) async throws {
        try await dbQueue.write { db in try message.update(db) }
    }

    public func messages(for conversationID: UUID) async throws -> [Message] {
        try await dbQueue.read { db in
            try Message
                .filter(Column("conversationID") == conversationID)
                .order(Column("createdAt"))
                .fetchAll(db)
        }
    }
}
