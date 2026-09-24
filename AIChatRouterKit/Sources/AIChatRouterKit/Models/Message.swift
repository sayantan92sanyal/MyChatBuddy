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
    /// JSON-encoded `[SearchCitation]`, or nil if the response used no web search.
    /// Stored as plain text (not a join table) since it's a small list always
    /// fetched alongside the message. Use `encodeCitations`/`decodeCitations` to
    /// convert at the UI/ViewModel boundary rather than working with raw JSON.
    public var citationsJSON: String?

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
        latencyMS: Int? = nil,
        citationsJSON: String? = nil
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
        self.citationsJSON = citationsJSON
    }

    public static func encodeCitations(_ citations: [SearchCitation]?) -> String? {
        guard let citations, !citations.isEmpty else { return nil }
        guard let data = try? JSONEncoder().encode(citations) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func decodeCitations(_ json: String?) -> [SearchCitation]? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([SearchCitation].self, from: data)
    }
}

extension Message.Role: DatabaseValueConvertible {}

extension Message: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "message"
}
