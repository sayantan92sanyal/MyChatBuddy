import Foundation
import GRDB

public struct Conversation: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var tokenTotalInput: Int
    public var tokenTotalOutput: Int

    public init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        tokenTotalInput: Int = 0,
        tokenTotalOutput: Int = 0
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.tokenTotalInput = tokenTotalInput
        self.tokenTotalOutput = tokenTotalOutput
    }
}

extension Conversation: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "conversation"
}
