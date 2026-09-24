import Foundation
import GRDB

public struct AppDatabase: Sendable {
    public let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) throws {
        self.dbQueue = dbQueue
        try Self.migrator.migrate(dbQueue)
    }

    public static func openDefault() throws -> AppDatabase {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = appSupport.appendingPathComponent("AIChatRouter", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbURL = dir.appendingPathComponent("db.sqlite")
        let dbQueue = try DatabaseQueue(path: dbURL.path)
        return try AppDatabase(dbQueue: dbQueue)
    }

    public static func openInMemory() throws -> AppDatabase {
        try AppDatabase(dbQueue: try DatabaseQueue())
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "conversation") { t in
                t.column("id", .blob).primaryKey()
                t.column("title", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("tokenTotalInput", .integer).notNull().defaults(to: 0)
                t.column("tokenTotalOutput", .integer).notNull().defaults(to: 0)
            }

            try db.create(table: "message") { t in
                t.column("id", .blob).primaryKey()
                t.column("conversationID", .blob).notNull()
                    .references("conversation", onDelete: .cascade)
                t.column("role", .text).notNull()
                t.column("content", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("providerID", .text)
                t.column("modelID", .text)
                t.column("tier", .text)
                t.column("inputTokens", .integer)
                t.column("outputTokens", .integer)
                t.column("latencyMS", .integer)
            }
            try db.create(
                index: "idx_message_conversation_createdAt",
                on: "message",
                columns: ["conversationID", "createdAt"]
            )

            try db.create(table: "routing_decision") { t in
                t.column("id", .blob).primaryKey()
                t.column("messageID", .blob)
                    .references("message", onDelete: .setNull)
                t.column("conversationID", .blob).notNull()
                    .references("conversation", onDelete: .cascade)
                t.column("query", .text).notNull()
                t.column("tier", .text).notNull()
                t.column("reasoning", .text)
                t.column("latencyMS", .integer).notNull()
                t.column("downgradedFrom", .text)
                t.column("downgradeReason", .text)
                t.column("createdAt", .datetime).notNull()
            }

            try db.create(table: "usage_event") { t in
                t.column("id", .blob).primaryKey()
                t.column("conversationID", .blob).notNull()
                t.column("messageID", .blob)
                t.column("providerID", .text).notNull()
                t.column("tier", .text).notNull()
                t.column("modelID", .text).notNull()
                t.column("inputTokens", .integer).notNull()
                t.column("outputTokens", .integer).notNull()
                t.column("estimatedCostUSD", .double).notNull().defaults(to: 0)
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(
                index: "idx_usage_event_createdAt",
                on: "usage_event",
                columns: ["createdAt"]
            )
            try db.create(
                index: "idx_usage_event_provider_tier",
                on: "usage_event",
                columns: ["providerID", "tier"]
            )
        }

        migrator.registerMigration("v2") { db in
            try db.alter(table: "message") { t in
                t.add(column: "citationsJSON", .text)
            }
        }

        return migrator
    }
}
