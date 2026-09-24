import Foundation
import GRDB

public struct UsageStore: Sendable {
    public struct PeriodTotal: Sendable, Equatable {
        public let providerID: ProviderID
        public let tier: ModelTier
        public let inputTokens: Int
        public let outputTokens: Int
        public let costUSD: Double
    }

    private let dbQueue: DatabaseQueue

    public init(database: AppDatabase) {
        self.dbQueue = database.dbQueue
    }

    public func record(_ usage: UsageRecord) async throws {
        try await dbQueue.write { db in try usage.insert(db) }
    }

    public func events(for conversationID: UUID) async throws -> [UsageRecord] {
        try await dbQueue.read { db in
            try UsageRecord
                .filter(Column("conversationID") == conversationID)
                .order(Column("createdAt"))
                .fetchAll(db)
        }
    }

    /// Aggregated token/cost totals grouped by provider and tier over [startDate, endDate).
    public func totals(from startDate: Date, to endDate: Date) async throws -> [PeriodTotal] {
        try await dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT providerID,
                       tier,
                       SUM(inputTokens) AS inputTokens,
                       SUM(outputTokens) AS outputTokens,
                       SUM(estimatedCostUSD) AS costUSD
                FROM usage_event
                WHERE createdAt >= ? AND createdAt < ?
                GROUP BY providerID, tier
                """,
                arguments: [startDate, endDate]
            )
            return rows.compactMap { row -> PeriodTotal? in
                guard
                    let providerRaw: String = row["providerID"],
                    let provider = ProviderID(rawValue: providerRaw),
                    let tierRaw: String = row["tier"],
                    let tier = ModelTier(rawValue: tierRaw)
                else { return nil }
                return PeriodTotal(
                    providerID: provider,
                    tier: tier,
                    inputTokens: row["inputTokens"] ?? 0,
                    outputTokens: row["outputTokens"] ?? 0,
                    costUSD: row["costUSD"] ?? 0
                )
            }
        }
    }

    public func totalSpend(from startDate: Date, to endDate: Date) async throws -> Double {
        try await dbQueue.read { db in
            try Double.fetchOne(
                db,
                sql: """
                SELECT COALESCE(SUM(estimatedCostUSD), 0) FROM usage_event
                WHERE createdAt >= ? AND createdAt < ?
                """,
                arguments: [startDate, endDate]
            ) ?? 0
        }
    }

    public func callCount(tier: ModelTier, from startDate: Date, to endDate: Date) async throws -> Int {
        try await dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*) FROM usage_event
                WHERE tier = ? AND createdAt >= ? AND createdAt < ?
                """,
                arguments: [tier.rawValue, startDate, endDate]
            ) ?? 0
        }
    }

    public func conversationTokenTotal(_ conversationID: UUID) async throws -> Int {
        try await dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: """
                SELECT COALESCE(SUM(inputTokens + outputTokens), 0) FROM usage_event
                WHERE conversationID = ?
                """,
                arguments: [conversationID]
            ) ?? 0
        }
    }
}
