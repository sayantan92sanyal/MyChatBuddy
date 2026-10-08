import Foundation
import GRDB

public struct ImageAttachment: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var conversationID: UUID
    public var messageID: UUID
    public var filename: String
    public var imageData: Data
    public var sizeBytes: Int
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        conversationID: UUID,
        messageID: UUID,
        filename: String,
        imageData: Data,
        sizeBytes: Int,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.conversationID = conversationID
        self.messageID = messageID
        self.filename = filename
        self.imageData = imageData
        self.sizeBytes = sizeBytes
        self.createdAt = createdAt
    }
}

extension ImageAttachment: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "image_attachment"
}
