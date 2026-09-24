import Foundation
import GRDB

/// A logged routing decision: the `RoutingDecision` output plus the query/conversation
/// context needed later for tuning/debugging the router.
public struct RoutingDecisionRow: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var messageID: UUID?
    public var conversationID: UUID
    public var query: String
    public var tier: ModelTier
    public var reasoning: String?
    public var latencyMS: Int
    public var downgradedFrom: ModelTier?
    public var downgradeReason: String?
    public var createdAt: Date
}

extension RoutingDecisionRow: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "routing_decision"
}

public struct RoutingLogStore: Sendable {
    private let dbQueue: DatabaseQueue

    public init(database: AppDatabase) {
        self.dbQueue = database.dbQueue
    }

    @discardableResult
    public func record(
        conversationID: UUID,
        query: String,
        decision: RoutingDecision,
        messageID: UUID? = nil
    ) async throws -> RoutingDecisionRow {
        let row = RoutingDecisionRow(
            id: UUID(),
            messageID: messageID,
            conversationID: conversationID,
            query: query,
            tier: decision.tier,
            reasoning: decision.reasoning,
            latencyMS: decision.latencyMS,
            downgradedFrom: decision.downgradedFrom,
            downgradeReason: decision.downgradeReason,
            createdAt: Date()
        )
        try await dbQueue.write { db in try row.insert(db) }
        return row
    }

    public func decisions(for conversationID: UUID) async throws -> [RoutingDecisionRow] {
        try await dbQueue.read { db in
            try RoutingDecisionRow
                .filter(Column("conversationID") == conversationID)
                .order(Column("createdAt"))
                .fetchAll(db)
        }
    }
}
