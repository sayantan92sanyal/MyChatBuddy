import Foundation
import MLXLMCommon

/// Default `QueryRouter`: runs a short, deterministic classification pass on the local
/// MLX model, distinct from (but sharing the same cached model instance as) the
/// full-answer local provider. Outputs a fixed single-word label rather than JSON —
/// small quantized models are far more reliable at a closed 3-token vocabulary than
/// well-formed JSON under a tight token budget, which matters for the sub-second
/// latency this classification pass needs to hit.
public struct PromptedLocalQueryRouter: QueryRouter, Sendable {
    private let modelManager: LocalModelManager
    private let modelID: String

    public init(modelManager: LocalModelManager, modelID: String) {
        self.modelManager = modelManager
        self.modelID = modelID
    }

    public func classify(_ context: RoutingContext) async throws -> RoutingDecision {
        let start = Date()
        do {
            let container = try await modelManager.loadedContainer(for: modelID)

            // Deliberately NOT passing context.recentTurns as ChatSession history: live
            // testing showed that once this small model sees realistic prior dialogue
            // turns, it drifts into "continue the conversation" mode and stops reliably
            // following the classification/SEARCH-detection instructions — even with a
            // strengthened system prompt telling it to ignore history's topic. An empty
            // history keeps the classification call isolated and deterministic; only the
            // answering model (not this classifier) needs the real conversation context.
            let session = ChatSession(
                container,
                instructions: Self.systemPrompt(bias: context.sensitivityBias),
                history: [],
                generateParameters: GenerateParameters(maxTokens: 12, temperature: 0)
            )

            let response = try await session.respond(to: context.candidateQuery)
            let latencyMS = Int(Date().timeIntervalSince(start) * 1000)
            return Self.parse(response: response, latencyMS: latencyMS)
        } catch {
            // Fail-safe, never fail-open to a paid tier: if the classifier itself
            // is unavailable, route locally rather than risking an unwanted cloud call.
            let latencyMS = Int(Date().timeIntervalSince(start) * 1000)
            return RoutingDecision(
                tier: .local,
                reasoning: "classifier unavailable — safe fallback (\(error.localizedDescription))",
                latencyMS: latencyMS
            )
        }
    }

    private static func systemPrompt(bias: RoutingSensitivity) -> String {
        let biasNote: String
        switch bias {
        case .preferLocal:
            biasNote = "Bias: prefer LOCAL unless escalation is clearly necessary."
        case .balanced:
            biasNote = "Bias: balance cost and capability normally."
        case .preferCloud:
            biasNote = "Bias: prefer escalating to FAST or ADVANCED when there is any doubt."
        }
        return """
        You are a query router for an AI assistant. Classify the user's latest message \
        into exactly one label based on how much reasoning depth, up-to-date/external \
        knowledge, or long-form creative output it needs.

        LOCAL - simple factual questions, small talk, short edits — a small on-device \
        model answers these well.
        FAST - moderate complexity: multi-step reasoning, summarization, everyday coding help.
        ADVANCED - hard reasoning, complex or long-form writing, highly technical or \
        nuanced tasks.

        \(biasNote)

        Respond with exactly one word on the first line: LOCAL, FAST, or ADVANCED. If the \
        query also needs current or external information you don't already have (e.g. \
        today's news, current prices, recent events, anything time-sensitive), add the \
        word SEARCH right after it on the same line, separated by a space (e.g. "FAST \
        SEARCH"). Optionally add a short reason on a second line.
        """
    }

    /// `internal` (not `private`) so tests can exercise the parsing logic directly,
    /// matching the pattern used by `SSEClient.parse`/`SSEClient.lines`.
    static func parse(response: String, latencyMS: Int) -> RoutingDecision {
        let lines = response.split(separator: "\n", maxSplits: 1).map(String.init)
        let firstLine = (lines.first ?? "").uppercased()
        let reasoning = lines.count > 1 ? lines[1].trimmingCharacters(in: .whitespaces) : nil

        // Whole-word matching, not substring: a bare `.contains("SEARCH")` would
        // also match "RESEARCH", which the model can plausibly write on the first
        // line itself under the tight 12-token budget (e.g. "ADVANCED - research").
        let words = Set(firstLine.split(whereSeparator: { !$0.isLetter }).map(String.init))

        let tier: ModelTier
        if words.contains("ADVANCED") {
            tier = .cloudAdvanced
        } else if words.contains("FAST") {
            tier = .cloudFast
        } else {
            tier = .local
        }

        let needsWebSearch = words.contains("SEARCH")

        return RoutingDecision(tier: tier, reasoning: reasoning, latencyMS: latencyMS, needsWebSearch: needsWebSearch)
    }
}
