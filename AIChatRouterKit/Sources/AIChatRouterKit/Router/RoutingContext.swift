import Foundation

public enum RoutingSensitivity: String, Codable, Sendable {
    case preferLocal
    case balanced
    case preferCloud
}

/// Everything a `QueryRouter` needs to classify one turn: the pre-trimmed recent
/// history (see `ContextWindowBuilder`), the new query, and the user's cost/quality bias.
public struct RoutingContext: Sendable {
    public let conversationID: UUID
    /// NOT currently consumed by `PromptedLocalQueryRouter` (the only `QueryRouter`
    /// in this codebase): live testing found that feeding realistic prior dialogue
    /// into the small on-device classifier's own session made it drift into
    /// "continue the conversation" mode and stop reliably classifying — see
    /// `PromptedLocalQueryRouter.classify`. Kept here for a router implementation
    /// that can use it safely (e.g. a cloud-hosted classifier).
    public let recentTurns: [ChatTurn]
    public let candidateQuery: String
    public let sensitivityBias: RoutingSensitivity

    public init(
        conversationID: UUID,
        recentTurns: [ChatTurn],
        candidateQuery: String,
        sensitivityBias: RoutingSensitivity = .balanced
    ) {
        self.conversationID = conversationID
        self.recentTurns = recentTurns
        self.candidateQuery = candidateQuery
        self.sensitivityBias = sensitivityBias
    }
}
