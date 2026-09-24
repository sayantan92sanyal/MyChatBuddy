import Foundation
import GRDB

public struct UsageRecord: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var conversationID: UUID
    public var messageID: UUID?
    public var providerID: ProviderID
    public var tier: ModelTier
    public var modelID: String
    public var inputTokens: Int
    public var outputTokens: Int
    public var estimatedCostUSD: Double
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        conversationID: UUID,
        messageID: UUID? = nil,
        providerID: ProviderID,
        tier: ModelTier,
        modelID: String,
        inputTokens: Int,
        outputTokens: Int,
        estimatedCostUSD: Double = 0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.conversationID = conversationID
        self.messageID = messageID
        self.providerID = providerID
        self.tier = tier
        self.modelID = modelID
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.estimatedCostUSD = estimatedCostUSD
        self.createdAt = createdAt
    }
}

extension UsageRecord: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "usage_event"
}
