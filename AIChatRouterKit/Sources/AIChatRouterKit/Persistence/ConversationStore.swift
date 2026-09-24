import Foundation
import GRDB

public struct ConversationStore: Sendable {
    private let dbQueue: DatabaseQueue

    public init(database: AppDatabase) {
        self.dbQueue = database.dbQueue
    }

    public func create(_ conversation: Conversation) async throws {
        try await dbQueue.write { db in try conversation.insert(db) }
    }

    public func update(_ conversation: Conversation) async throws {
        try await dbQueue.write { db in try conversation.update(db) }
    }

    public func delete(id: UUID) async throws {
        _ = try await dbQueue.write { db in try Conversation.deleteOne(db, key: id) }
    }

    public func fetch(id: UUID) async throws -> Conversation? {
        try await dbQueue.read { db in try Conversation.fetchOne(db, key: id) }
    }

    public func fetchAll() async throws -> [Conversation] {
        try await dbQueue.read { db in
            try Conversation
                .order(Column("updatedAt").desc)
                .fetchAll(db)
        }
    }

    public func addTokenUsage(id: UUID, input: Int, output: Int) async throws {
        try await dbQueue.write { db in
            guard var conversation = try Conversation.fetchOne(db, key: id) else { return }
            conversation.tokenTotalInput += input
            conversation.tokenTotalOutput += output
            conversation.updatedAt = Date()
            try conversation.update(db)
        }
    }
}
