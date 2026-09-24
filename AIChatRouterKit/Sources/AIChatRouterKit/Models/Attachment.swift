import Foundation
import GRDB

public struct Attachment: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var conversationID: UUID
    public var filename: String
    public var fileType: String
    public var extractedText: String
    public var sizeBytes: Int
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        conversationID: UUID,
        filename: String,
        fileType: String,
        extractedText: String,
        sizeBytes: Int,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.conversationID = conversationID
        self.filename = filename
        self.fileType = fileType
        self.extractedText = extractedText
        self.sizeBytes = sizeBytes
        self.createdAt = createdAt
    }
}

extension Attachment: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "attachment"
}
