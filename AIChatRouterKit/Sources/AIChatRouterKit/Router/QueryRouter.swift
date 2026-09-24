/// Classifies a query into a `ModelTier`. This is the core-IP module of the app —
/// distinct from the chat UI and provider integrations so its prompt/logic can be
/// iterated on independently. `PromptedLocalQueryRouter` is the default implementation.
public protocol QueryRouter: Sendable {
    func classify(_ context: RoutingContext) async throws -> RoutingDecision
}
