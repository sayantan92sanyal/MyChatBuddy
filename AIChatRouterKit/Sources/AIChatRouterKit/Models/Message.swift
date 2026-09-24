import Foundation
import GRDB

public struct Message: Identifiable, Codable, Sendable, Equatable {
    public enum Role: String, Codable, Sendable {
        case system
        case user
        case assistant
    }

    public var id: UUID
    public var conversationID: UUID
    public var role: Role
    public var content: String
    public var createdAt: Date
    public var providerID: ProviderID?
    public var modelID: String?
    public var tier: ModelTier?
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var latencyMS: Int?

    public init(
        id: UUID = UUID(),
        conversationID: UUID,
        role: Role,
        content: String,
        createdAt: Date = Date(),
        providerID: ProviderID? = nil,
        modelID: String? = nil,
        tier: ModelTier? = nil,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        latencyMS: Int? = nil
    ) {
        self.id = id
        self.conversationID = conversationID
        self.role = role
        self.content = content
        self.createdAt = createdAt
        self.providerID = providerID
        self.modelID = modelID
        self.tier = tier
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.latencyMS = latencyMS
    }
}

extension Message.Role: DatabaseValueConvertible {}

extension Message: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "message"
}
