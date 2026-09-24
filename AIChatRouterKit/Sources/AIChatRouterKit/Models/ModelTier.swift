import GRDB

public enum ModelTier: String, Codable, CaseIterable, Sendable {
    case local
    case cloudFast
    case cloudAdvanced
}

extension ModelTier: Comparable {
    private var sortOrder: Int {
        switch self {
        case .local: return 0
        case .cloudFast: return 1
        case .cloudAdvanced: return 2
        }
    }

    public static func < (lhs: ModelTier, rhs: ModelTier) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }
}

extension ModelTier: DatabaseValueConvertible {}
