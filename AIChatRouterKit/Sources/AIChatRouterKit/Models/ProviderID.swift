import GRDB

public enum ProviderID: String, Codable, Sendable, CaseIterable {
    case localMLX
    case anthropic
    case openAI
}

extension ProviderID: DatabaseValueConvertible {}
