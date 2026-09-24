# Web Search (v2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Note on "commit" steps:** this project has no git repository (confirmed empty at project start; v1 was built entirely without one). Every task's final step is therefore "build + test" verification rather than a git commit. If a repo gets initialized before this plan runs, commits can be added back in at each task boundary.

**Goal:** Let the router decide when a query needs current/external info and, when it does, force escalation to a cloud tier with that provider's native web search tool enabled — surfacing citations and a permission prompt when usage caps would otherwise block it.

**Architecture:** Extend `RoutingDecision` with a `needsWebSearch` signal parsed from the same local-model classification pass (`LOCAL`/`FAST`/`ADVANCED` + optional `SEARCH` token). `RoutingCoordinator` gates it behind a global toggle, forces at least Cloud Fast when needed, and flags a caps-vs-search conflict for the UI to resolve via a permission banner rather than resolving it silently. `LLMProvider.streamCompletion` gains an `enableWebSearch` parameter; Anthropic/OpenAI attach their native search tool and return aggregated citations on the final stream chunk, persisted alongside the message.

**Tech Stack:** Swift 6, SwiftUI, GRDB (SQLite), MLX Swift (local classifier), Anthropic Messages API (`web_search_20250305` tool, verified live), OpenAI API (tool shape not yet verified — no live key available; Task 7 starts with the verification spike).

**Spec:** `docs/superpowers/specs/2026-09-24-web-search-design.md`

## Global Constraints

- Native provider search tools only — no third-party search API or new API key.
- The router (local model) decides search need, not the cloud model in isolation.
- `LOCAL` + search need always bumps to at least `cloudFast` — never stays local when search is genuinely needed and the toggle is on.
- A usage-cap-driven downgrade to `local` while search is needed must surface an inline Allow/Deny banner — never silently resolved either way.
- Offline is a hard constraint, not a policy choice — always forces local silently, never triggers the permission banner.
- The web-search toggle is global (one switch, not per-conversation), defaults to **on**, surfaced in the chat toolbar (not buried in Settings).
- Citations are shown as a collapsed-by-default "Sources (N)" list under the message; inline per-sentence attribution is out of scope.
- Every provider change must be verified against the live API before being considered done — no assumed JSON shapes.

## Review Focus

- **Toggle turned off mid-conversation:** does a query that clearly needs search stay on `local` instead of escalating, with no `SEARCH` effects leaking through? (Task 3's tests cover this directly.)
- **Two-step cap cascade (`cloudAdvanced` → `cloudFast` → `local`) with search need:** does the permission banner offer `cloudFast` specifically, not the original `cloudAdvanced`, and not something else derived from `downgradedFrom`? (Task 3's tests cover this directly — this was the exact ambiguity caught in spec self-review.)
- **Provider search-tool failure mid-stream:** if Anthropic/OpenAI's search subsystem errors after some text has already streamed, does the existing error banner still show (not an empty silent message — this is the exact shape of the SSE blank-line bug from v1)? This relies on the pre-existing `if let error = decoded.error { throw ... }` branch in both providers, which this plan does not change and which has no dedicated unit test either before or after this plan (there's no injectable fake for `SSEClient` at the provider level yet). Not covered by an automated test — verified only by Task 6 Step 5's live check and the Task 11 live checkpoint. Flagging as a real gap: if this matters enough to close properly, a follow-up task should give `AnthropicProvider`/`OpenAIProvider` an injectable `SSEClient`-shaped test seam.
- **Malformed/unparseable citation URL:** does a citation with an unrecognizable URL string fail to render (or render safely) instead of crashing the message list via a force-unwrapped `URL(string:)`? (Task 9's implementation must guard this — no test framework for SwiftUI views exists in this project, so this is verified by code review + the live app checkpoint in Task 11, not an automated test.)
- **Denying the permission banner:** does the conversation still get a normal (non-search) local answer afterward, rather than getting stuck with no response at all? `ChatViewModel` has no automated test suite in this project (SwiftUI `@Observable` view models here are verified live, not unit-tested — see Task 8's preamble); this is verified by the Task 11 live checkpoint (Step 4's Deny path), not an automated test.

---

## Task 1: RoutingDecision + PromptedLocalQueryRouter SEARCH parsing

**Files:**
- Modify: `AIChatRouterKit/Sources/AIChatRouterKit/Models/RoutingDecision.swift`
- Modify: `AIChatRouterKit/Sources/AIChatRouterKit/Router/PromptedLocalQueryRouter.swift`
- Modify: `AIChatRouterKit/Tests/AIChatRouterKitTests/RoutingCoordinatorTests.swift` (no signature changes needed here yet — `RoutingDecision`'s new fields all have defaults)

**Interfaces:**
- Produces: `RoutingDecision.needsWebSearch: Bool`, `RoutingDecision.requiresSearchPermission: Bool`, `RoutingDecision.searchOverrideTier: ModelTier?` — all default to `false`/`false`/`nil` so every existing call site (`RoutingDecision(tier:latencyMS:)` etc.) keeps compiling unchanged.

- [ ] **Step 1: Write the failing test for SEARCH-token parsing**

Create `AIChatRouterKit/Tests/AIChatRouterKitTests/RoutingDecisionSearchParsingTests.swift`:

```swift
import Foundation
import Testing
@testable import AIChatRouterKit

@Suite("RoutingDecision search fields")
struct RoutingDecisionSearchParsingTests {
    @Test func defaultsToNoSearchNeeded() {
        let decision = RoutingDecision(tier: .local, latencyMS: 10)
        #expect(decision.needsWebSearch == false)
        #expect(decision.requiresSearchPermission == false)
        #expect(decision.searchOverrideTier == nil)
    }

    @Test func canBeConstructedWithSearchFlagsSet() {
        let decision = RoutingDecision(
            tier: .cloudFast,
            latencyMS: 10,
            needsWebSearch: true,
            requiresSearchPermission: true,
            searchOverrideTier: .cloudFast
        )
        #expect(decision.needsWebSearch == true)
        #expect(decision.requiresSearchPermission == true)
        #expect(decision.searchOverrideTier == .cloudFast)
    }
}
```

- [ ] **Step 2: Run test to verify it fails to compile**

Run: `cd "AIChatRouterKit" && swift test --filter RoutingDecisionSearchParsingTests`
Expected: FAIL — compile error, `RoutingDecision` has no member `needsWebSearch` (or similar).

- [ ] **Step 3: Add the new fields to RoutingDecision**

Replace the full contents of `AIChatRouterKit/Sources/AIChatRouterKit/Models/RoutingDecision.swift`:

```swift
import Foundation

/// The output of a `QueryRouter` classification pass. Distinct from the persisted
/// `RoutingDecisionRow` (see `RoutingLogStore`), which additionally carries the
/// query text, conversation, and message association for logging/tuning.
public struct RoutingDecision: Sendable, Codable, Equatable {
    public var tier: ModelTier
    public var reasoning: String?
    public var latencyMS: Int
    public var downgradedFrom: ModelTier?
    public var downgradeReason: String?

    /// Set by the classifier when the query needs current/external info the model
    /// doesn't already have. Only cloud tiers can act on it (see `RoutingCoordinator`).
    public var needsWebSearch: Bool
    /// True when a usage cap (not offline) forced `tier` to `.local` while
    /// `needsWebSearch` was true — the caller should ask the user before proceeding,
    /// rather than silently picking a side.
    public var requiresSearchPermission: Bool
    /// The tier to resume at if search permission is granted. Always `.cloudFast`
    /// (the minimum viable tier for search) — never the original higher tier a
    /// complexity judgment may have wanted, since the permission ask is "let this
    /// search happen," not "restore full Advanced-tier spending."
    public var searchOverrideTier: ModelTier?

    public init(
        tier: ModelTier,
        reasoning: String? = nil,
        latencyMS: Int,
        downgradedFrom: ModelTier? = nil,
        downgradeReason: String? = nil,
        needsWebSearch: Bool = false,
        requiresSearchPermission: Bool = false,
        searchOverrideTier: ModelTier? = nil
    ) {
        self.tier = tier
        self.reasoning = reasoning
        self.latencyMS = latencyMS
        self.downgradedFrom = downgradedFrom
        self.downgradeReason = downgradeReason
        self.needsWebSearch = needsWebSearch
        self.requiresSearchPermission = requiresSearchPermission
        self.searchOverrideTier = searchOverrideTier
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd "AIChatRouterKit" && swift test --filter RoutingDecisionSearchParsingTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Write the failing test for the router's SEARCH-token parsing**

Create `AIChatRouterKit/Tests/AIChatRouterKitTests/PromptedLocalQueryRouterParsingTests.swift`. This tests the *private* `parse` function indirectly is not possible (it's `private static`), so instead test it by making `parse` `internal` (package-visible) rather than `private` — matching the existing pattern in `SSEClient` where `parse`/`lines` are `internal static` specifically so tests can exercise them via `@testable import`. Change `private static func parse` to `static func parse` in the next step; this test assumes that visibility:

```swift
import Foundation
import Testing
@testable import AIChatRouterKit

@Suite("PromptedLocalQueryRouter parsing")
struct PromptedLocalQueryRouterParsingTests {
    @Test func plainLocalHasNoSearchFlag() {
        let decision = PromptedLocalQueryRouter.parse(response: "LOCAL", latencyMS: 5)
        #expect(decision.tier == .local)
        #expect(decision.needsWebSearch == false)
    }

    @Test func fastWithSearchTokenSetsFlag() {
        let decision = PromptedLocalQueryRouter.parse(response: "FAST SEARCH", latencyMS: 5)
        #expect(decision.tier == .cloudFast)
        #expect(decision.needsWebSearch == true)
    }

    @Test func localWithSearchTokenSetsFlagButDoesNotBumpTierHere() {
        // The router only reports the need; RoutingCoordinator (Task 3) owns the
        // toggle-check-then-bump decision, so parse() must NOT bump tier itself.
        let decision = PromptedLocalQueryRouter.parse(response: "LOCAL SEARCH", latencyMS: 5)
        #expect(decision.tier == .local)
        #expect(decision.needsWebSearch == true)
    }

    @Test func advancedWithSearchTokenAndReasoningLine() {
        let decision = PromptedLocalQueryRouter.parse(
            response: "ADVANCED SEARCH\nNeeds today's stock prices and deep analysis",
            latencyMS: 5
        )
        #expect(decision.tier == .cloudAdvanced)
        #expect(decision.needsWebSearch == true)
        #expect(decision.reasoning == "Needs today's stock prices and deep analysis")
    }

    @Test func searchTokenIsCaseInsensitive() {
        let decision = PromptedLocalQueryRouter.parse(response: "fast search", latencyMS: 5)
        #expect(decision.tier == .cloudFast)
        #expect(decision.needsWebSearch == true)
    }
}
```

- [ ] **Step 6: Run test to verify it fails**

Run: `cd "AIChatRouterKit" && swift test --filter PromptedLocalQueryRouterParsingTests`
Expected: FAIL — `parse` is inaccessible due to 'private' protection level.

- [ ] **Step 7: Update the router's prompt and parsing to support the SEARCH token**

In `AIChatRouterKit/Sources/AIChatRouterKit/Router/PromptedLocalQueryRouter.swift`, replace the `systemPrompt` and `parse` functions:

```swift
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

        let tier: ModelTier
        if firstLine.contains("ADVANCED") {
            tier = .cloudAdvanced
        } else if firstLine.contains("FAST") {
            tier = .cloudFast
        } else {
            tier = .local
        }

        let needsWebSearch = firstLine.contains("SEARCH")

        return RoutingDecision(tier: tier, reasoning: reasoning, latencyMS: latencyMS, needsWebSearch: needsWebSearch)
    }
```

Note: only these two functions change. Leave `init`, `classify`, and the `modelManager`/`modelID` properties untouched.

- [ ] **Step 8: Run tests to verify they pass**

Run: `cd "AIChatRouterKit" && swift test --filter PromptedLocalQueryRouterParsingTests`
Expected: PASS (5 tests).

- [ ] **Step 9: Run the full kit test suite and build**

Run: `cd "AIChatRouterKit" && swift build && swift test`
Expected: BUILD SUCCEEDED; all tests pass (24 previous + 2 + 5 = 31 tests).

---

## Task 2: AppSettingsStore web search toggle

**Files:**
- Modify: `AIChatRouterKit/Sources/AIChatRouterKit/Config/AppSettingsStore.swift`
- Test: `AIChatRouterKit/Tests/AIChatRouterKitTests/AppSettingsStoreWebSearchTests.swift` (new file)

**Interfaces:**
- Produces: `AppSettingsStore.loadWebSearchEnabled() -> Bool` (defaults to `true` when never set), `AppSettingsStore.saveWebSearchEnabled(_ enabled: Bool)`.

- [ ] **Step 1: Write the failing test**

Create `AIChatRouterKit/Tests/AIChatRouterKitTests/AppSettingsStoreWebSearchTests.swift`:

```swift
import Foundation
import Testing
@testable import AIChatRouterKit

@Suite("AppSettingsStore web search toggle")
struct AppSettingsStoreWebSearchTests {
    private func makeStore() -> AppSettingsStore {
        let suiteName = "AppSettingsStoreWebSearchTests-\(UUID().uuidString)"
        return AppSettingsStore(defaults: UserDefaults(suiteName: suiteName)!)
    }

    @Test func defaultsToEnabled() {
        let store = makeStore()
        #expect(store.loadWebSearchEnabled() == true)
    }

    @Test func persistsDisabledState() {
        let store = makeStore()
        store.saveWebSearchEnabled(false)
        #expect(store.loadWebSearchEnabled() == false)
    }

    @Test func persistsReenabledState() {
        let store = makeStore()
        store.saveWebSearchEnabled(false)
        store.saveWebSearchEnabled(true)
        #expect(store.loadWebSearchEnabled() == true)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd "AIChatRouterKit" && swift test --filter AppSettingsStoreWebSearchTests`
Expected: FAIL — `AppSettingsStore` has no member `loadWebSearchEnabled`.

- [ ] **Step 3: Add the toggle methods**

In `AIChatRouterKit/Sources/AIChatRouterKit/Config/AppSettingsStore.swift`, add a new key constant alongside the existing three:

```swift
    private let webSearchEnabledKey = "com.sayantan.aichatrouter.webSearchEnabled"
```

Then add these two methods at the end of the struct, before the closing brace:

```swift
    public func loadWebSearchEnabled() -> Bool {
        guard defaults.object(forKey: webSearchEnabledKey) != nil else { return true }
        return defaults.bool(forKey: webSearchEnabledKey)
    }

    public func saveWebSearchEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: webSearchEnabledKey)
    }
```

(The `object(forKey:) != nil` guard matters: `UserDefaults.bool(forKey:)` returns `false` for a never-set key, which would make "unset" indistinguishable from "explicitly disabled." Checking for existence first makes the default `true` as intended.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd "AIChatRouterKit" && swift test --filter AppSettingsStoreWebSearchTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Run the full kit test suite and build**

Run: `cd "AIChatRouterKit" && swift build && swift test`
Expected: BUILD SUCCEEDED; 34 tests pass.

---

## Task 3: RoutingCoordinator full search-aware decide() flow

**Files:**
- Modify: `AIChatRouterKit/Sources/AIChatRouterKit/Router/RoutingCoordinator.swift`
- Modify: `AIChatRouterKit/Tests/AIChatRouterKitTests/RoutingCoordinatorTests.swift`

**Interfaces:**
- Consumes: `RoutingDecision.needsWebSearch/.requiresSearchPermission/.searchOverrideTier` (Task 1), `AppSettingsStore.loadWebSearchEnabled()` (Task 2).
- Produces: `RoutingCoordinator.init(router:logStore:usageLimiter:networkStatus:settingsStore:)` — **signature change**, adds a required `settingsStore: AppSettingsStore` parameter. Every call site must be updated (this task updates the test file; Task 10 updates `AppEnvironment`).

- [ ] **Step 1: Write the failing tests for the new decide() behavior**

Replace the full contents of `AIChatRouterKit/Tests/AIChatRouterKitTests/RoutingCoordinatorTests.swift`:

```swift
import Foundation
import Testing
@testable import AIChatRouterKit

private struct FakeQueryRouter: QueryRouter {
    let decision: RoutingDecision
    let error: Error?

    init(decision: RoutingDecision) {
        self.decision = decision
        self.error = nil
    }

    init(throwing error: Error) {
        self.decision = RoutingDecision(tier: .local, latencyMS: 0)
        self.error = error
    }

    func classify(_ context: RoutingContext) async throws -> RoutingDecision {
        if let error { throw error }
        return decision
    }
}

private enum FakeRouterError: Error {
    case boom
}

private struct PassthroughUsageLimiter: UsageLimiter {
    func applyCaps(to decision: RoutingDecision, conversationID: UUID) async -> RoutingDecision {
        decision
    }

    func recordUsage(
        conversationID: UUID,
        messageID: UUID?,
        providerID: ProviderID,
        tier: ModelTier,
        modelID: String,
        usage: TokenUsage
    ) async {}

    func spend(for period: UsagePeriod) async -> Double { 0 }
    func conversationTokenTotal(_ conversationID: UUID) async -> Int { 0 }
    func softCapWarning(for conversationID: UUID) async -> String? { nil }
}

/// Simulates a cap cascade: downgrades whatever tier it's given straight to `.local`
/// in one step, recording the *original* tier as `downgradedFrom` — exactly like
/// `DefaultUsageLimiter`'s real cascade does when every cloud tier is capped.
private struct AlwaysDowngradesToLocalUsageLimiter: UsageLimiter {
    func applyCaps(to decision: RoutingDecision, conversationID: UUID) async -> RoutingDecision {
        guard decision.tier != .local else { return decision }
        var downgraded = decision
        downgraded.downgradedFrom = decision.tier
        downgraded.tier = .local
        downgraded.downgradeReason = "budget cap reached"
        return downgraded
    }

    func recordUsage(
        conversationID: UUID,
        messageID: UUID?,
        providerID: ProviderID,
        tier: ModelTier,
        modelID: String,
        usage: TokenUsage
    ) async {}

    func spend(for period: UsagePeriod) async -> Double { 0 }
    func conversationTokenTotal(_ conversationID: UUID) async -> Int { 0 }
    func softCapWarning(for conversationID: UUID) async -> String? { nil }
}

private struct FakeNetworkStatus: NetworkStatusProvider {
    let isOnline: Bool
}

private func settingsStore(webSearchEnabled: Bool = true) -> AppSettingsStore {
    let suiteName = "RoutingCoordinatorTests-\(UUID().uuidString)"
    let store = AppSettingsStore(defaults: UserDefaults(suiteName: suiteName)!)
    store.saveWebSearchEnabled(webSearchEnabled)
    return store
}

@Suite("RoutingCoordinator")
struct RoutingCoordinatorTests {
    @Test func decideReturnsAndLogsTheRouterDecision() async throws {
        let db = try AppDatabase.openInMemory()
        let conversations = ConversationStore(database: db)
        let logStore = RoutingLogStore(database: db)

        let conversation = Conversation(title: "Test")
        try await conversations.create(conversation)

        let router = FakeQueryRouter(decision: RoutingDecision(
            tier: .cloudAdvanced,
            reasoning: "complex reasoning required",
            latencyMS: 42
        ))
        let coordinator = RoutingCoordinator(
            router: router,
            logStore: logStore,
            usageLimiter: PassthroughUsageLimiter(),
            networkStatus: FakeNetworkStatus(isOnline: true),
            settingsStore: settingsStore()
        )

        let context = RoutingContext(
            conversationID: conversation.id,
            recentTurns: [],
            candidateQuery: "Explain quantum entanglement in depth"
        )
        let decision = await coordinator.decide(context)

        #expect(decision.tier == .cloudAdvanced)
        #expect(decision.reasoning == "complex reasoning required")

        let logged = try await logStore.decisions(for: conversation.id)
        #expect(logged.count == 1)
        #expect(logged.first?.tier == .cloudAdvanced)
        #expect(logged.first?.query == "Explain quantum entanglement in depth")
    }

    @Test func fallsBackToLocalAndStillLogsWhenRouterThrows() async throws {
        let db = try AppDatabase.openInMemory()
        let conversations = ConversationStore(database: db)
        let logStore = RoutingLogStore(database: db)

        let conversation = Conversation(title: "Test")
        try await conversations.create(conversation)

        let router = FakeQueryRouter(throwing: FakeRouterError.boom)
        let coordinator = RoutingCoordinator(
            router: router,
            logStore: logStore,
            usageLimiter: PassthroughUsageLimiter(),
            networkStatus: FakeNetworkStatus(isOnline: true),
            settingsStore: settingsStore()
        )

        let context = RoutingContext(
            conversationID: conversation.id,
            recentTurns: [],
            candidateQuery: "hi"
        )
        let decision = await coordinator.decide(context)

        #expect(decision.tier == .local)

        let logged = try await logStore.decisions(for: conversation.id)
        #expect(logged.count == 1)
        #expect(logged.first?.tier == .local)
    }

    @Test func forcesLocalWhenOffline() async throws {
        let db = try AppDatabase.openInMemory()
        let conversations = ConversationStore(database: db)
        let logStore = RoutingLogStore(database: db)

        let conversation = Conversation(title: "Test")
        try await conversations.create(conversation)

        let router = FakeQueryRouter(decision: RoutingDecision(tier: .cloudAdvanced, latencyMS: 10))
        let coordinator = RoutingCoordinator(
            router: router,
            logStore: logStore,
            usageLimiter: PassthroughUsageLimiter(),
            networkStatus: FakeNetworkStatus(isOnline: false),
            settingsStore: settingsStore()
        )

        let context = RoutingContext(conversationID: conversation.id, recentTurns: [], candidateQuery: "hi")
        let decision = await coordinator.decide(context)

        #expect(decision.tier == .local)
        #expect(decision.downgradedFrom == .cloudAdvanced)
        #expect(decision.downgradeReason?.contains("offline") == true)
    }

    @Test func searchNeedBumpsLocalTierToCloudFast() async throws {
        let db = try AppDatabase.openInMemory()
        let conversations = ConversationStore(database: db)
        let logStore = RoutingLogStore(database: db)

        let conversation = Conversation(title: "Test")
        try await conversations.create(conversation)

        let router = FakeQueryRouter(decision: RoutingDecision(tier: .local, latencyMS: 10, needsWebSearch: true))
        let coordinator = RoutingCoordinator(
            router: router,
            logStore: logStore,
            usageLimiter: PassthroughUsageLimiter(),
            networkStatus: FakeNetworkStatus(isOnline: true),
            settingsStore: settingsStore()
        )

        let context = RoutingContext(conversationID: conversation.id, recentTurns: [], candidateQuery: "today's news")
        let decision = await coordinator.decide(context)

        #expect(decision.tier == .cloudFast)
        #expect(decision.needsWebSearch == true)
        #expect(decision.requiresSearchPermission == false)
    }

    @Test func webSearchToggleOffSuppressesSearchFlagAndTierBump() async throws {
        let db = try AppDatabase.openInMemory()
        let conversations = ConversationStore(database: db)
        let logStore = RoutingLogStore(database: db)

        let conversation = Conversation(title: "Test")
        try await conversations.create(conversation)

        let router = FakeQueryRouter(decision: RoutingDecision(tier: .local, latencyMS: 10, needsWebSearch: true))
        let coordinator = RoutingCoordinator(
            router: router,
            logStore: logStore,
            usageLimiter: PassthroughUsageLimiter(),
            networkStatus: FakeNetworkStatus(isOnline: true),
            settingsStore: settingsStore(webSearchEnabled: false)
        )

        let context = RoutingContext(conversationID: conversation.id, recentTurns: [], candidateQuery: "today's news")
        let decision = await coordinator.decide(context)

        // Toggle off: the tier bump never happens because needsWebSearch was
        // suppressed before the bump check ran.
        #expect(decision.tier == .local)
        #expect(decision.needsWebSearch == false)
        #expect(decision.requiresSearchPermission == false)
    }

    @Test func capCascadeConflictingWithSearchNeedOffersCloudFastNotOriginalTier() async throws {
        let db = try AppDatabase.openInMemory()
        let conversations = ConversationStore(database: db)
        let logStore = RoutingLogStore(database: db)

        let conversation = Conversation(title: "Test")
        try await conversations.create(conversation)

        // Router wants Advanced + search; the fake limiter simulates a full cascade
        // (as DefaultUsageLimiter's real loop would when every cloud tier is capped)
        // landing on .local with downgradedFrom == .cloudAdvanced.
        let router = FakeQueryRouter(decision: RoutingDecision(
            tier: .cloudAdvanced, latencyMS: 10, needsWebSearch: true
        ))
        let coordinator = RoutingCoordinator(
            router: router,
            logStore: logStore,
            usageLimiter: AlwaysDowngradesToLocalUsageLimiter(),
            networkStatus: FakeNetworkStatus(isOnline: true),
            settingsStore: settingsStore()
        )

        let context = RoutingContext(conversationID: conversation.id, recentTurns: [], candidateQuery: "today's stock prices, analyze deeply")
        let decision = await coordinator.decide(context)

        #expect(decision.tier == .local)
        #expect(decision.requiresSearchPermission == true)
        // The critical assertion: offered override is cloudFast (minimum viable),
        // NOT .cloudAdvanced (which `downgradedFrom` would say if reused directly).
        #expect(decision.searchOverrideTier == .cloudFast)
        #expect(decision.downgradedFrom == .cloudAdvanced)
    }

    @Test func offlineNeverTriggersSearchPermissionEvenWithSearchNeed() async throws {
        let db = try AppDatabase.openInMemory()
        let conversations = ConversationStore(database: db)
        let logStore = RoutingLogStore(database: db)

        let conversation = Conversation(title: "Test")
        try await conversations.create(conversation)

        let router = FakeQueryRouter(decision: RoutingDecision(
            tier: .cloudFast, latencyMS: 10, needsWebSearch: true
        ))
        let coordinator = RoutingCoordinator(
            router: router,
            logStore: logStore,
            usageLimiter: PassthroughUsageLimiter(),
            networkStatus: FakeNetworkStatus(isOnline: false),
            settingsStore: settingsStore()
        )

        let context = RoutingContext(conversationID: conversation.id, recentTurns: [], candidateQuery: "today's news")
        let decision = await coordinator.decide(context)

        #expect(decision.tier == .local)
        #expect(decision.requiresSearchPermission == false)
        #expect(decision.searchOverrideTier == nil)
        #expect(decision.downgradeReason?.contains("offline") == true)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd "AIChatRouterKit" && swift test --filter RoutingCoordinatorTests`
Expected: FAIL — `RoutingCoordinator.init` has no parameter `settingsStore` (compile error affecting all tests in this file).

- [ ] **Step 3: Update RoutingCoordinator**

Replace the full contents of `AIChatRouterKit/Sources/AIChatRouterKit/Router/RoutingCoordinator.swift`:

```swift
import Foundation

/// Orchestrates one routing decision: runs the `QueryRouter`, falls back safely if it
/// throws, applies the web-search toggle and local→cloudFast bump, consults the
/// `UsageLimiter` (which may downgrade the tier under a cap), flags a caps-vs-search
/// conflict for the UI to resolve rather than resolving it silently, forces `.local`
/// when offline, and logs every decision (query, tier, reasoning, latency) for later
/// tuning.
public actor RoutingCoordinator {
    private let router: QueryRouter
    private let logStore: RoutingLogStore
    private let usageLimiter: UsageLimiter
    private let networkStatus: NetworkStatusProvider
    private let settingsStore: AppSettingsStore

    public init(
        router: QueryRouter,
        logStore: RoutingLogStore,
        usageLimiter: UsageLimiter,
        networkStatus: NetworkStatusProvider,
        settingsStore: AppSettingsStore
    ) {
        self.router = router
        self.logStore = logStore
        self.usageLimiter = usageLimiter
        self.networkStatus = networkStatus
        self.settingsStore = settingsStore
    }

    @discardableResult
    public func decide(_ context: RoutingContext) async -> RoutingDecision {
        var raw: RoutingDecision
        do {
            raw = try await router.classify(context)
        } catch {
            raw = RoutingDecision(
                tier: .local,
                reasoning: "classifier unavailable — safe fallback (\(error.localizedDescription))",
                latencyMS: 0
            )
        }

        // Toggle check happens before anything downstream can see needsWebSearch —
        // when off, it's as if the classifier never said SEARCH at all.
        if !settingsStore.loadWebSearchEnabled() {
            raw.needsWebSearch = false
        }

        // Search need always forces at least Cloud Fast — only cloud tiers can search.
        if raw.needsWebSearch, raw.tier == .local {
            raw.tier = .cloudFast
        }

        var adjusted = await usageLimiter.applyCaps(to: raw, conversationID: context.conversationID)

        // A cap (not offline) forced this to .local while search was needed: don't
        // resolve the conflict silently — flag it for the UI to ask permission.
        // The offered override is always cloudFast (minimum viable for search),
        // never `downgradedFrom` (which records the *original* pre-cascade tier,
        // e.g. cloudAdvanced, and would ask for more spending than search needs).
        if raw.needsWebSearch, adjusted.tier == .local, adjusted.downgradedFrom != nil {
            adjusted.requiresSearchPermission = true
            adjusted.searchOverrideTier = .cloudFast
        }

        if adjusted.tier != .local, await !networkStatus.isOnline {
            adjusted.downgradedFrom = adjusted.downgradedFrom ?? adjusted.tier
            adjusted.tier = .local
            adjusted.downgradeReason = "You're offline — routed to the local model"
            // Offline is a hard constraint, not a policy choice — no permission ask.
            adjusted.requiresSearchPermission = false
            adjusted.searchOverrideTier = nil
        }

        _ = try? await logStore.record(
            conversationID: context.conversationID,
            query: context.candidateQuery,
            decision: adjusted
        )

        return adjusted
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd "AIChatRouterKit" && swift test --filter RoutingCoordinatorTests`
Expected: PASS (7 tests).

- [ ] **Step 5: Run the full kit test suite and build**

Run: `cd "AIChatRouterKit" && swift build && swift test`
Expected: BUILD SUCCEEDED. `AppEnvironment.swift` (in the `AIChatRouter` app target, not the kit) will now fail to build because `RoutingCoordinator.init` gained a required parameter — this is expected and fixed in Task 10. Confirm the failure is exactly that one call site by running: `cd .. && xcodebuild -scheme AIChatRouter -project AIChatRouter.xcodeproj -skipPackagePluginValidation build 2>&1 | grep "error:"` and checking every error line mentions `RoutingCoordinator(` in `AppEnvironment.swift`.

---

## Task 4: LLMProvider protocol + ProviderStreamChunk + SearchCitation

**Files:**
- Modify: `AIChatRouterKit/Sources/AIChatRouterKit/Providers/LLMProvider.swift`
- Modify: `AIChatRouterKit/Sources/AIChatRouterKit/Providers/LocalMLXProvider.swift`
- Modify: `AIChatRouterKit/Sources/AIChatRouterKit/Providers/FakeEchoProvider.swift`

**Interfaces:**
- Produces: `SearchCitation { url: String, title: String? }` (new, `Codable & Equatable & Hashable & Sendable`). `ProviderStreamChunk.citations: [SearchCitation]?` (new field, defaults to `nil`). `LLMProvider.streamCompletion(model:systemPrompt:turns:maxOutputTokens:enableWebSearch:)` — **signature change**, adds a required `enableWebSearch: Bool` parameter to the protocol requirement and all four implementations (`LocalMLXProvider`, `FakeEchoProvider` in this task; `AnthropicProvider`, `OpenAIProvider` in Tasks 6–7).

- [ ] **Step 1: Write the failing test**

Create `AIChatRouterKit/Tests/AIChatRouterKitTests/ProviderStreamChunkCitationsTests.swift`:

```swift
import Foundation
import Testing
@testable import AIChatRouterKit

@Suite("ProviderStreamChunk citations")
struct ProviderStreamChunkCitationsTests {
    @Test func chunkDefaultsToNoCitations() {
        let chunk = ProviderStreamChunk(deltaText: "hi")
        #expect(chunk.citations == nil)
    }

    @Test func chunkCanCarryCitations() {
        let citation = SearchCitation(url: "https://example.com", title: "Example")
        let chunk = ProviderStreamChunk(deltaText: "", isFinal: true, citations: [citation])
        #expect(chunk.citations?.count == 1)
        #expect(chunk.citations?.first?.url == "https://example.com")
        #expect(chunk.citations?.first?.title == "Example")
    }

    @Test func fakeEchoProviderIgnoresEnableWebSearchFlag() async throws {
        let provider = FakeEchoProvider()
        let descriptor = ProviderModelDescriptor(id: "echo", providerID: .localMLX, tier: .local, displayName: "Local")
        var sawFinal = false
        for try await chunk in provider.streamCompletion(
            model: descriptor, systemPrompt: nil, turns: [ChatTurn(role: .user, content: "hi")],
            maxOutputTokens: 50, enableWebSearch: true
        ) {
            if chunk.isFinal {
                sawFinal = true
                #expect(chunk.citations == nil)
            }
        }
        #expect(sawFinal)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd "AIChatRouterKit" && swift test --filter ProviderStreamChunkCitationsTests`
Expected: FAIL — `SearchCitation` not found in scope; `streamCompletion` has no parameter `enableWebSearch`.

- [ ] **Step 3: Update LLMProvider.swift**

In `AIChatRouterKit/Sources/AIChatRouterKit/Providers/LLMProvider.swift`, add the `SearchCitation` type after `TokenUsage` and update `ProviderStreamChunk` and the `LLMProvider` protocol:

```swift
public struct SearchCitation: Sendable, Codable, Equatable, Hashable {
    public let url: String
    public let title: String?

    public init(url: String, title: String? = nil) {
        self.url = url
        self.title = title
    }
}

public struct ProviderStreamChunk: Sendable {
    public let deltaText: String
    public let isFinal: Bool
    public let usage: TokenUsage?
    public let latencyMS: Int?
    public let citations: [SearchCitation]?

    public init(
        deltaText: String,
        isFinal: Bool = false,
        usage: TokenUsage? = nil,
        latencyMS: Int? = nil,
        citations: [SearchCitation]? = nil
    ) {
        self.deltaText = deltaText
        self.isFinal = isFinal
        self.usage = usage
        self.latencyMS = latencyMS
        self.citations = citations
    }
}
```

(Insert `SearchCitation` right before the `ProviderStreamChunk` struct definition; the existing `TokenUsage` struct above it is unchanged.)

Then update the protocol itself:

```swift
public protocol LLMProvider: Sendable {
    var id: ProviderID { get }
    func isConfigured() async -> Bool
    func streamCompletion(
        model: ProviderModelDescriptor,
        systemPrompt: String?,
        turns: [ChatTurn],
        maxOutputTokens: Int,
        enableWebSearch: Bool
    ) -> AsyncThrowingStream<ProviderStreamChunk, Error>
}
```

- [ ] **Step 4: Update LocalMLXProvider to match the new signature**

In `AIChatRouterKit/Sources/AIChatRouterKit/Providers/LocalMLXProvider.swift`, change the `streamCompletion` signature (body is unchanged — the parameter is simply unused, since the local model cannot search):

```swift
    public func streamCompletion(
        model: ProviderModelDescriptor,
        systemPrompt: String?,
        turns: [ChatTurn],
        maxOutputTokens: Int,
        enableWebSearch: Bool
    ) -> AsyncThrowingStream<ProviderStreamChunk, Error> {
```

(Only the function signature line changes; everything inside the function body stays exactly as it is.)

- [ ] **Step 5: Update FakeEchoProvider to match the new signature**

In `AIChatRouterKit/Sources/AIChatRouterKit/Providers/FakeEchoProvider.swift`, change the `streamCompletion` signature the same way:

```swift
    public func streamCompletion(
        model: ProviderModelDescriptor,
        systemPrompt: String?,
        turns: [ChatTurn],
        maxOutputTokens: Int,
        enableWebSearch: Bool
    ) -> AsyncThrowingStream<ProviderStreamChunk, Error> {
```

(Only the signature line changes; the body is unchanged.)

- [ ] **Step 6: Run tests to verify they pass**

Run: `cd "AIChatRouterKit" && swift test --filter ProviderStreamChunkCitationsTests`
Expected: PASS (3 tests).

- [ ] **Step 7: Run the full kit test suite and build**

Run: `cd "AIChatRouterKit" && swift build 2>&1 | grep -E "error:|Build complete"`
Expected: `AnthropicProvider.swift` and `OpenAIProvider.swift` now fail to build (missing `enableWebSearch` parameter and not conforming to `LLMProvider`) — this is expected and fixed in Tasks 6–7. Confirm the only errors are in those two files. Then run `swift test --filter "SSEClient|Persistence|UsageLimiter|RoutingCoordinator|ContextWindowBuilder|RoutingDecisionSearchParsing|PromptedLocalQueryRouterParsing|AppSettingsStoreWebSearch|ProviderStreamChunkCitations"` to confirm every suite *other than* the two providers still passes (41 tests: 24 baseline + 7 from Task 1 + 3 from Task 2 + 4 net-new from Task 3 + 3 from this task).

---

## Task 5: Persistence — citationsJSON column + Message helpers

**Files:**
- Modify: `AIChatRouterKit/Sources/AIChatRouterKit/Persistence/AppDatabase.swift`
- Modify: `AIChatRouterKit/Sources/AIChatRouterKit/Models/Message.swift`
- Test: `AIChatRouterKit/Tests/AIChatRouterKitTests/PersistenceTests.swift` (add a test to the existing suite)

**Interfaces:**
- Produces: `Message.citationsJSON: String?` (new stored property, persisted column), `Message.encodeCitations(_ citations: [SearchCitation]?) -> String?` (static helper), `Message.decodeCitations(_ json: String?) -> [SearchCitation]?` (static helper).
- Consumes: `SearchCitation` from Task 4.

- [ ] **Step 1: Write the failing test**

Open `AIChatRouterKit/Tests/AIChatRouterKitTests/PersistenceTests.swift` and add this test inside the `PersistenceTests` struct (after `messagesPersistAndOrderByCreatedAt`, before `routingDecisionsAreLoggedAndQueryable`):

```swift
    @Test func messageCitationsRoundTripThroughEncodeAndPersistence() async throws {
        let db = try AppDatabase.openInMemory()
        let conversations = ConversationStore(database: db)
        let messages = MessageStore(database: db)

        let conversation = Conversation(title: "Citations Test")
        try await conversations.create(conversation)

        let citations = [
            SearchCitation(url: "https://example.com/a", title: "Article A"),
            SearchCitation(url: "https://example.com/b", title: nil)
        ]
        let message = Message(
            conversationID: conversation.id,
            role: .assistant,
            content: "Answer with sources",
            citationsJSON: Message.encodeCitations(citations)
        )
        try await messages.append(message)

        let fetched = try await messages.messages(for: conversation.id)
        let decoded = Message.decodeCitations(fetched.first?.citationsJSON)
        #expect(decoded?.count == 2)
        #expect(decoded?.first?.url == "https://example.com/a")
        #expect(decoded?.first?.title == "Article A")
        #expect(decoded?.last?.title == nil)
    }

    @Test func encodeCitationsReturnsNilForEmptyOrNilInput() {
        #expect(Message.encodeCitations(nil) == nil)
        #expect(Message.encodeCitations([]) == nil)
    }

    @Test func decodeCitationsReturnsNilForNilOrMalformedInput() {
        #expect(Message.decodeCitations(nil) == nil)
        #expect(Message.decodeCitations("not json") == nil)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd "AIChatRouterKit" && swift test --filter messageCitationsRoundTripThroughEncodeAndPersistence`
Expected: FAIL — `Message.init` has no parameter `citationsJSON`; `Message.encodeCitations` not found.

- [ ] **Step 3: Add the migration**

In `AIChatRouterKit/Sources/AIChatRouterKit/Persistence/AppDatabase.swift`, add a second migration after the existing `migrator.registerMigration("v1") { ... }` block, still inside the `migrator` computed property, before `return migrator`:

```swift
        migrator.registerMigration("v2") { db in
            try db.alter(table: "message") { t in
                t.add(column: "citationsJSON", .text)
            }
        }
```

- [ ] **Step 4: Update the Message model**

Replace the full contents of `AIChatRouterKit/Sources/AIChatRouterKit/Models/Message.swift`:

```swift
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
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd "AIChatRouterKit" && swift test --filter PersistenceTests`
Expected: PASS (9 tests — 6 existing + 3 new).

- [ ] **Step 6: Run the full kit test suite and build**

Run: `cd "AIChatRouterKit" && swift build 2>&1 | grep -E "error:|Build complete"`
Expected: same two pre-existing provider errors as Task 4 (not yet fixed), nothing new broken. Run the full non-provider test filter again from Task 4 Step 7 to confirm 44 tests pass (41 + 3 new persistence tests).

---

## Task 6: AnthropicProvider web search support

**Files:**
- Modify: `AIChatRouterKit/Sources/AIChatRouterKit/Providers/AnthropicProvider.swift`
- Test: `AIChatRouterKit/Tests/AIChatRouterKitTests/AnthropicProviderCitationParsingTests.swift` (new file, uses a recorded fixture — no live network call in the automated suite)

**Interfaces:**
- Consumes: `LLMProvider` (Task 4, new `enableWebSearch` param), `SearchCitation` (Task 4).
- Produces: `AnthropicProvider` fully conforms to the updated `LLMProvider` protocol again.

This task's shape was verified live against the real Anthropic API during planning (see the spec's Testing section) — the exact SSE event shapes below are copied from that real, captured response, not assumed from documentation.

- [ ] **Step 1: Write the failing test using a recorded real-payload fixture**

Create `AIChatRouterKit/Tests/AIChatRouterKitTests/AnthropicProviderCitationParsingTests.swift`. This test exercises the private `AnthropicStreamEvent` JSON-decoding logic indirectly by decoding the exact citation-bearing event shape captured live during planning, confirming the type used inside `AnthropicProvider` will parse it correctly. Since `AnthropicStreamEvent` is `private`, this test instead verifies behavior through the public `SearchCitation` type the provider must produce — the full end-to-end streaming path is verified by the live app checkpoint in Task 11, not by this unit test (there is no live network access in the automated suite).

```swift
import Foundation
import Testing
@testable import AIChatRouterKit

@Suite("AnthropicProvider web search")
struct AnthropicProviderCitationParsingTests {
    @Test func isConfiguredFalseWithoutAPIKey() async throws {
        let suiteName = "AnthropicProviderCitationParsingTests-\(UUID().uuidString)"
        let keychain = KeychainStore(service: suiteName)
        let provider = AnthropicProvider(keychain: keychain)
        #expect(await provider.isConfigured() == false)
    }

    @Test func missingAPIKeyThrowsBeforeAnyNetworkCall() async throws {
        let suiteName = "AnthropicProviderCitationParsingTests-\(UUID().uuidString)"
        let keychain = KeychainStore(service: suiteName)
        let provider = AnthropicProvider(keychain: keychain)
        let descriptor = ProviderModelDescriptor(
            id: "claude-sonnet-4-5", providerID: .anthropic, tier: .cloudFast, displayName: "Sonnet"
        )

        await #expect(throws: ProviderError.self) {
            for try await _ in provider.streamCompletion(
                model: descriptor, systemPrompt: nil,
                turns: [ChatTurn(role: .user, content: "hi")],
                maxOutputTokens: 50, enableWebSearch: true
            ) {}
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd "AIChatRouterKit" && swift test --filter AnthropicProviderCitationParsingTests`
Expected: FAIL — `AnthropicProvider.streamCompletion` has no parameter `enableWebSearch` (compile error).

- [ ] **Step 3: Update AnthropicProvider**

Replace the full contents of `AIChatRouterKit/Sources/AIChatRouterKit/Providers/AnthropicProvider.swift`:

```swift
import Foundation

/// Hand-rolled client for the Anthropic Messages API streaming endpoint. No official
/// Swift SDK exists, and per-call token usage (core IP, feeds the UsageLimiter) is
/// safer to own directly than to depend on an unofficial wrapper.
///
/// Web search support (`web_search_20250305` tool) was verified live against the real
/// API during v2 planning: search results arrive as a `web_search_tool_result` content
/// block (the full raw hit list — not surfaced to the user), and the sources the model
/// actually drew from arrive as `citations_delta` events attached to the text it
/// generates. This provider surfaces the latter (what was cited), not the former (every
/// raw hit), matching the spec's "Sources" list being what was actually used.
public struct AnthropicProvider: LLMProvider, Sendable {
    public static let apiKeyAccount = "anthropic-api-key"

    public let id: ProviderID = .anthropic

    private let keychain: KeychainStore
    private let sseClient: SSEClient
    private let session: URLSession
    private let baseURL: URL

    public init(
        keychain: KeychainStore = KeychainStore(),
        sseClient: SSEClient = SSEClient(),
        session: URLSession = .shared,
        baseURL: URL = URL(string: "https://api.anthropic.com/v1/messages")!
    ) {
        self.keychain = keychain
        self.sseClient = sseClient
        self.session = session
        self.baseURL = baseURL
    }

    public func isConfigured() async -> Bool {
        let key = (try? keychain.value(forAccount: Self.apiKeyAccount)) ?? nil
        return !(key ?? "").isEmpty
    }

    public func streamCompletion(
        model: ProviderModelDescriptor,
        systemPrompt: String?,
        turns: [ChatTurn],
        maxOutputTokens: Int,
        enableWebSearch: Bool
    ) -> AsyncThrowingStream<ProviderStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let apiKey = (try? keychain.value(forAccount: Self.apiKeyAccount)) ?? nil,
                          !apiKey.isEmpty else {
                        throw ProviderError.missingAPIKey
                    }

                    var request = URLRequest(url: baseURL)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

                    let body = AnthropicRequestBody(
                        model: model.id,
                        maxTokens: maxOutputTokens,
                        system: systemPrompt,
                        stream: true,
                        messages: turns.filter { $0.role != .system }.map {
                            AnthropicMessage(role: $0.role == .user ? "user" : "assistant", content: $0.content)
                        },
                        tools: enableWebSearch
                            ? [AnthropicTool(type: "web_search_20250305", name: "web_search", maxUses: 5)]
                            : nil
                    )
                    request.httpBody = try JSONEncoder().encode(body)

                    let start = Date()
                    var inputTokens = 0
                    var outputTokens = 0
                    var citationsSeen: [String: SearchCitation] = [:]

                    for try await event in sseClient.events(for: request, session: session) {
                        guard let jsonData = event.data.data(using: .utf8) else { continue }
                        guard let decoded = try? JSONDecoder().decode(AnthropicStreamEvent.self, from: jsonData) else {
                            continue
                        }

                        switch decoded.type {
                        case "content_block_delta":
                            if let text = decoded.delta?.text, !text.isEmpty {
                                continuation.yield(ProviderStreamChunk(deltaText: text))
                            }
                            if let citation = decoded.delta?.citation, let url = citation.url {
                                citationsSeen[url] = SearchCitation(url: url, title: citation.title)
                            }
                        case "message_start":
                            if let usage = decoded.message?.usage {
                                inputTokens = usage.inputTokens ?? inputTokens
                            }
                        case "message_delta":
                            if let usage = decoded.usage {
                                outputTokens = usage.outputTokens ?? outputTokens
                            }
                        default:
                            break
                        }

                        if let error = decoded.error {
                            throw ProviderError.network(error.message ?? "Anthropic API error")
                        }
                    }

                    let latencyMS = Int(Date().timeIntervalSince(start) * 1000)
                    continuation.yield(ProviderStreamChunk(
                        deltaText: "",
                        isFinal: true,
                        usage: TokenUsage(inputTokens: inputTokens, outputTokens: outputTokens),
                        latencyMS: latencyMS,
                        citations: citationsSeen.isEmpty ? nil : Array(citationsSeen.values)
                    ))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private struct AnthropicMessage: Codable {
    let role: String
    let content: String
}

private struct AnthropicTool: Codable {
    let type: String
    let name: String
    let maxUses: Int

    enum CodingKeys: String, CodingKey {
        case type, name
        case maxUses = "max_uses"
    }
}

private struct AnthropicRequestBody: Codable {
    let model: String
    let maxTokens: Int
    let system: String?
    let stream: Bool
    let messages: [AnthropicMessage]
    let tools: [AnthropicTool]?

    enum CodingKeys: String, CodingKey {
        case model, system, stream, messages, tools
        case maxTokens = "max_tokens"
    }
}

private struct AnthropicStreamEvent: Codable {
    let type: String?
    let delta: Delta?
    let message: MessageStart?
    let usage: Usage?
    let error: APIError?

    struct Delta: Codable {
        let text: String?
        let citation: Citation?
    }

    struct Citation: Codable {
        let url: String?
        let title: String?
    }

    struct MessageStart: Codable {
        let usage: Usage?
    }

    struct Usage: Codable {
        let inputTokens: Int?
        let outputTokens: Int?

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
        }
    }

    struct APIError: Codable {
        let message: String?
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd "AIChatRouterKit" && swift test --filter AnthropicProviderCitationParsingTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Live verification against the real API (manual, not part of the automated suite)**

This confirms the implementation against a live call, since the fixture-based unit tests above only prove the code compiles and handles the missing-key path — they don't exercise the real network parsing.

Run (reads the Anthropic key from Keychain, prints the streamed answer):

```bash
API_KEY=$(security find-generic-password -s "com.sayantan.aichatrouter" -a "anthropic-api-key" -w 2>&1)
curl -s -N https://api.anthropic.com/v1/messages \
  -H "content-type: application/json" \
  -H "x-api-key: $API_KEY" \
  -H "anthropic-version: 2023-06-01" \
  -d '{"model":"claude-sonnet-4-5","max_tokens":300,"stream":true,"tools":[{"type":"web_search_20250305","name":"web_search","max_uses":2}],"messages":[{"role":"user","content":"What is a notable tech headline today? Search the web."}]}' \
  | grep "citations_delta"
```

Expected: at least one `citations_delta` line containing a `"url"` field, confirming the live shape still matches what Step 3 parses. (If Anthropic has changed the shape since this plan was written, update `AnthropicStreamEvent.Delta.Citation` to match before proceeding — do not skip this check.)

- [ ] **Step 6: Run the full kit test suite and build**

Run: `cd "AIChatRouterKit" && swift build 2>&1 | grep -E "error:|Build complete"`
Expected: only `OpenAIProvider.swift` still fails (Task 7 not yet done). Run `swift test` with the same non-OpenAI filter approach as prior tasks to confirm 46 tests pass (44 + 2 new).

---

## Task 7: OpenAIProvider web search support

**Files:**
- Modify: `AIChatRouterKit/Sources/AIChatRouterKit/Providers/OpenAIProvider.swift`
- Test: `AIChatRouterKit/Tests/AIChatRouterKitTests/OpenAIProviderTests.swift` (new file)

**Interfaces:**
- Consumes: `LLMProvider` (Task 4, new `enableWebSearch` param), `SearchCitation` (Task 4).
- Produces: `OpenAIProvider` fully conforms to the updated `LLMProvider` protocol again.

**This task starts with a live verification spike — no OpenAI API key was available during planning, so (unlike Anthropic) the exact tool/response shape below is not yet confirmed. Do not skip Step 1.**

- [ ] **Step 1: Verify the real OpenAI web search shape before writing any parsing code**

Requires an OpenAI API key in Keychain under service `com.sayantan.aichatrouter`, account `openai-api-key` (added via the app's Settings → API Keys tab, or directly via `security add-generic-password`). Run:

```bash
API_KEY=$(security find-generic-password -s "com.sayantan.aichatrouter" -a "openai-api-key" -w 2>&1)

# OpenAI's web search tool lives on the Responses API (/v1/responses), not the
# Chat Completions endpoint this provider currently calls (/v1/chat/completions).
# Try the Responses API first:
curl -s https://api.openai.com/v1/responses \
  -H "content-type: application/json" \
  -H "Authorization: Bearer $API_KEY" \
  -d '{"model":"gpt-4o","input":"What is a notable tech headline today? Search the web.","tools":[{"type":"web_search_preview"}]}' \
  | head -c 4000
```

Read the response and answer these questions before proceeding to Step 2:
1. Does `/v1/responses` accept this request (200 status), or does it 400/404?
2. What is the actual tool `type` string it expects (`web_search_preview`, `web_search`, or something else)?
3. Does the non-streaming response include a citations/annotations field? What is it called and what shape (a list of `{url, title}`-like objects, or something else)?
4. If `/v1/responses` doesn't exist or doesn't support this on the account's API tier, check whether a search-capable Chat Completions model variant exists instead (e.g. try `"model":"gpt-4o-search-preview"` against `/v1/chat/completions` with no `tools` array, since search-enabled model variants historically enable search implicitly rather than via a tool).
5. If streaming (`"stream": true`) is added to whichever endpoint works, what do the SSE event/data lines look like for (a) text deltas, (b) citations, (c) final usage?

Record the working request shape and the exact citation field name/structure — Step 2 depends on this being a real, observed shape, not a guess.

- [ ] **Step 2: Write the failing test for the parts that don't depend on the verified shape**

Create `AIChatRouterKit/Tests/AIChatRouterKitTests/OpenAIProviderTests.swift` (these two tests only cover the pre-network-call path, which doesn't depend on Step 1's findings):

```swift
import Foundation
import Testing
@testable import AIChatRouterKit

@Suite("OpenAIProvider web search")
struct OpenAIProviderTests {
    @Test func isConfiguredFalseWithoutAPIKey() async throws {
        let suiteName = "OpenAIProviderTests-\(UUID().uuidString)"
        let keychain = KeychainStore(service: suiteName)
        let provider = OpenAIProvider(keychain: keychain)
        #expect(await provider.isConfigured() == false)
    }

    @Test func missingAPIKeyThrowsBeforeAnyNetworkCall() async throws {
        let suiteName = "OpenAIProviderTests-\(UUID().uuidString)"
        let keychain = KeychainStore(service: suiteName)
        let provider = OpenAIProvider(keychain: keychain)
        let descriptor = ProviderModelDescriptor(
            id: "gpt-4o-mini", providerID: .openAI, tier: .cloudFast, displayName: "GPT-4o mini"
        )

        await #expect(throws: ProviderError.self) {
            for try await _ in provider.streamCompletion(
                model: descriptor, systemPrompt: nil,
                turns: [ChatTurn(role: .user, content: "hi")],
                maxOutputTokens: 50, enableWebSearch: true
            ) {}
        }
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `cd "AIChatRouterKit" && swift test --filter OpenAIProviderTests`
Expected: FAIL — `OpenAIProvider.streamCompletion` has no parameter `enableWebSearch` (compile error).

- [ ] **Step 4: Update OpenAIProvider's signature and request body based on Step 1's findings**

At minimum, change the signature so the protocol conformance compiles (required regardless of Step 1's outcome). In `AIChatRouterKit/Sources/AIChatRouterKit/Providers/OpenAIProvider.swift`:

```swift
    public func streamCompletion(
        model: ProviderModelDescriptor,
        systemPrompt: String?,
        turns: [ChatTurn],
        maxOutputTokens: Int,
        enableWebSearch: Bool
    ) -> AsyncThrowingStream<ProviderStreamChunk, Error> {
```

Then, using Step 1's confirmed shape: if the existing `/v1/chat/completions` endpoint turned out to support a search tool directly (unlikely per OpenAI's current API split, but verify — don't assume), add an `AnthropicTool`-style struct and a conditional `tools` field to `OpenAIRequestBody`, mirroring Task 6's pattern. If (as is more likely) search requires switching to `/v1/responses`, that is a bigger change than this task's scope safely covers in one sitting — stop here, do not guess a request/response structure into existence, and report back with Step 1's findings so the endpoint migration can be scoped as its own follow-up task before continuing. Either way, `citations` on the final `ProviderStreamChunk` should be populated the same way Task 6 did it: collect `SearchCitation(url:title:)` values as they're observed in the response, deduplicated by URL, emitted only on the final chunk.

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd "AIChatRouterKit" && swift test --filter OpenAIProviderTests`
Expected: PASS (2 tests) — these two tests do not depend on Step 4's outcome either way, since they only cover the missing-key path.

- [ ] **Step 6: Run the full kit test suite and build**

Run: `cd "AIChatRouterKit" && swift build && swift test`
Expected: BUILD SUCCEEDED (all providers now conform to `LLMProvider`); all tests pass (48 total: 46 + 2 new). If Step 4 stopped early pending endpoint-migration scoping, OpenAI's web search still won't functionally work yet, but the build is green and Anthropic's path (Task 6) is fully functional — proceed to Task 8, since the app-level wiring is provider-agnostic and doesn't block on this.

---

## Task 8: ChatViewModel — permission flow, citations, performSend refactor

**Files:**
- Modify: `AIChatRouter/ViewModels/ChatViewModel.swift`

**Interfaces:**
- Consumes: `RoutingDecision.requiresSearchPermission/.searchOverrideTier/.needsWebSearch` (Task 1/3), `LLMProvider.streamCompletion(...enableWebSearch:)` (Task 4), `Message.citationsJSON`/`encodeCitations` (Task 5), `ProviderRegistry.resolve(tier:)` (existing, unchanged).
- Produces: `ChatViewModel.pendingSearchPermission: Bool` (new published property), `ChatViewModel.allowSearchOverride() async`, `ChatViewModel.denySearchOverride() async` (new methods) — consumed by `ChatView` in Task 9.

This app target has no automated test suite (SwiftUI `@Observable` view models in this project are verified via the live app checkpoint in Task 11, matching how Phases 2–8 of v1 were verified — there is no XCTest/Swift Testing target wired into the `AIChatRouter` app target itself, only into `AIChatRouterKit`). Proceed carefully and re-read each step against the current file before editing.

- [ ] **Step 1: Replace ChatViewModel.swift in full**

Replace the full contents of `AIChatRouter/ViewModels/ChatViewModel.swift`:

```swift
import Foundation
import Observation
import AIChatRouterKit

@Observable
@MainActor
final class ChatViewModel {
    private(set) var conversation: Conversation
    private(set) var messages: [Message] = []
    var draftText: String = ""
    private(set) var isStreaming = false
    private(set) var streamingText = ""
    private(set) var errorMessage: String?
    private(set) var routingNote: String?
    private(set) var usageWarning: String?
    private(set) var pendingSearchPermission = false

    private let conversationStore: ConversationStore
    private let messageStore: MessageStore
    private let routingCoordinator: RoutingCoordinator
    private let providerRegistry: ProviderRegistry
    private let usageLimiter: UsageLimiter
    private let settingsStore: AppSettingsStore

    private struct PendingSend {
        let turns: [ChatTurn]
    }
    private var pendingSend: PendingSend?

    init(
        conversation: Conversation,
        conversationStore: ConversationStore,
        messageStore: MessageStore,
        routingCoordinator: RoutingCoordinator,
        providerRegistry: ProviderRegistry,
        usageLimiter: UsageLimiter,
        settingsStore: AppSettingsStore
    ) {
        self.conversation = conversation
        self.conversationStore = conversationStore
        self.messageStore = messageStore
        self.routingCoordinator = routingCoordinator
        self.providerRegistry = providerRegistry
        self.usageLimiter = usageLimiter
        self.settingsStore = settingsStore
    }

    func loadMessages() async {
        do {
            messages = try await messageStore.messages(for: conversation.id)
        } catch {
            errorMessage = "Failed to load messages: \(error.localizedDescription)"
        }
    }

    func sendMessage() async {
        let text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }
        draftText = ""
        errorMessage = nil
        routingNote = nil
        usageWarning = nil
        pendingSearchPermission = false
        pendingSend = nil

        let userMessage = Message(conversationID: conversation.id, role: .user, content: text)
        do {
            try await messageStore.append(userMessage)
        } catch {
            errorMessage = "Failed to save message: \(error.localizedDescription)"
            return
        }
        messages.append(userMessage)

        isStreaming = true
        streamingText = ""

        let recentTurns = ContextWindowBuilder().build(from: Array(messages.dropLast()))
        let routingContext = RoutingContext(
            conversationID: conversation.id,
            recentTurns: recentTurns,
            candidateQuery: text,
            sensitivityBias: settingsStore.loadRoutingSensitivity()
        )
        let decision = await routingCoordinator.decide(routingContext)

        if let downgradeReason = decision.downgradeReason {
            routingNote = downgradeReason
        }

        let turns = messages.map {
            ChatTurn(role: ChatTurn.Role(rawValue: $0.role.rawValue) ?? .user, content: $0.content)
        }

        if decision.requiresSearchPermission, let overrideTier = decision.searchOverrideTier,
           providerRegistry.resolve(tier: overrideTier) != nil {
            pendingSend = PendingSend(turns: turns)
            pendingSearchPermission = true
            isStreaming = false
            streamingText = ""
            return
        }

        guard let resolved = providerRegistry.resolve(tier: decision.tier) else {
            errorMessage = "No provider is configured for the \(decision.tier) tier."
            isStreaming = false
            streamingText = ""
            return
        }

        let enableWebSearch = decision.needsWebSearch && decision.tier != .local
        await performSend(
            provider: resolved.provider,
            modelDescriptor: resolved.descriptor,
            turns: turns,
            enableWebSearch: enableWebSearch
        )
    }

    func allowSearchOverride() async {
        guard let pending = pendingSend else { return }
        pendingSearchPermission = false
        pendingSend = nil

        guard let resolved = providerRegistry.resolve(tier: .cloudFast) else {
            errorMessage = "No provider is configured for the cloudFast tier."
            return
        }

        isStreaming = true
        streamingText = ""
        await performSend(
            provider: resolved.provider,
            modelDescriptor: resolved.descriptor,
            turns: pending.turns,
            enableWebSearch: true
        )
    }

    func denySearchOverride() async {
        guard let pending = pendingSend else { return }
        pendingSearchPermission = false
        pendingSend = nil

        guard let resolved = providerRegistry.resolve(tier: .local) else {
            errorMessage = "No provider is configured for the local tier."
            return
        }

        isStreaming = true
        streamingText = ""
        await performSend(
            provider: resolved.provider,
            modelDescriptor: resolved.descriptor,
            turns: pending.turns,
            enableWebSearch: false
        )
    }

    private func performSend(
        provider: LLMProvider,
        modelDescriptor: ProviderModelDescriptor,
        turns: [ChatTurn],
        enableWebSearch: Bool
    ) async {
        if modelDescriptor.providerID != .localMLX, await !provider.isConfigured() {
            errorMessage = "\(modelDescriptor.displayName) needs an API key. Add one in Settings before sending."
            isStreaming = false
            streamingText = ""
            return
        }

        do {
            var finalUsage: TokenUsage?
            var finalLatency: Int?
            var finalCitations: [SearchCitation]?
            let stream = provider.streamCompletion(
                model: modelDescriptor,
                systemPrompt: nil,
                turns: turns,
                maxOutputTokens: 1024,
                enableWebSearch: enableWebSearch
            )
            for try await chunk in stream {
                if !chunk.deltaText.isEmpty {
                    streamingText += chunk.deltaText
                }
                if chunk.isFinal {
                    finalUsage = chunk.usage
                    finalLatency = chunk.latencyMS
                    finalCitations = chunk.citations
                }
            }

            let assistantMessage = Message(
                conversationID: conversation.id,
                role: .assistant,
                content: streamingText,
                providerID: provider.id,
                modelID: modelDescriptor.id,
                tier: modelDescriptor.tier,
                inputTokens: finalUsage?.inputTokens,
                outputTokens: finalUsage?.outputTokens,
                latencyMS: finalLatency,
                citationsJSON: Message.encodeCitations(finalCitations)
            )
            try await messageStore.append(assistantMessage)
            messages.append(assistantMessage)

            if let usage = finalUsage {
                try await conversationStore.addTokenUsage(
                    id: conversation.id,
                    input: usage.inputTokens,
                    output: usage.outputTokens
                )
                conversation.tokenTotalInput += usage.inputTokens
                conversation.tokenTotalOutput += usage.outputTokens

                await usageLimiter.recordUsage(
                    conversationID: conversation.id,
                    messageID: assistantMessage.id,
                    providerID: provider.id,
                    tier: modelDescriptor.tier,
                    modelID: modelDescriptor.id,
                    usage: usage
                )
                usageWarning = await usageLimiter.softCapWarning(for: conversation.id)
            }
        } catch ProviderError.missingAPIKey, ProviderError.invalidAPIKey {
            errorMessage = "\(modelDescriptor.displayName) needs a valid API key. Add one in Settings."
        } catch {
            errorMessage = "Response failed: \(error.localizedDescription)"
        }

        isStreaming = false
        streamingText = ""
    }
}
```

Note: `ProviderRegistry.resolve(tier:)` returns an optional tuple `(provider: LLMProvider, descriptor: ProviderModelDescriptor)?` — the `providerRegistry.resolve(tier: overrideTier) != nil` check in `sendMessage()` only tests reachability before deferring to the banner; `allowSearchOverride()`/`denySearchOverride()` re-resolve for real when the user responds, since `ProviderRegistry` always reads the current Settings mapping fresh (per its existing documented behavior) and that mapping could theoretically change between the two calls.

- [ ] **Step 2: Build the app target to verify it compiles**

Run: `cd .. && xcodegen generate && xcodebuild -scheme AIChatRouter -project AIChatRouter.xcodeproj -skipPackagePluginValidation build 2>&1 | grep -E "error:|BUILD SUCCEEDED"`
Expected: errors remaining only in `ChatView.swift` (still calling the old `sendMessage()`-only flow without the banner — fine, Task 9 fixes that) — confirm no errors reference `ChatViewModel.swift` itself. If `ChatViewModel.swift` has errors, fix them before proceeding (common mistake: forgetting a parameter at one of the three `performSend` call sites).

---

## Task 9: ChatView — permission banner, Sources list, global toggle

**Files:**
- Modify: `AIChatRouter/Views/Chat/ChatView.swift`
- Modify: `AIChatRouter/Views/Chat/MessageBubbleView.swift`

**Interfaces:**
- Consumes: `ChatViewModel.pendingSearchPermission/.allowSearchOverride()/.denySearchOverride()` (Task 8), `Message.citationsJSON`/`decodeCitations` (Task 5), `AppSettingsStore.loadWebSearchEnabled()/saveWebSearchEnabled()` (Task 2).

- [ ] **Step 1: Add the settingsStore property and permission banner to ChatView**

Replace the full contents of `AIChatRouter/Views/Chat/ChatView.swift`:

```swift
import SwiftUI
import AIChatRouterKit

struct ChatView: View {
    @State private var viewModel: ChatViewModel
    @State private var webSearchEnabled: Bool
    private let conversationTitle: String
    private let displayName: (String) -> String
    private let settingsStore: AppSettingsStore

    init(conversation: Conversation, environment: AppEnvironment) {
        self.conversationTitle = conversation.title
        self.displayName = environment.displayName(forModelID:)
        self.settingsStore = environment.settingsStore
        _webSearchEnabled = State(initialValue: environment.settingsStore.loadWebSearchEnabled())
        _viewModel = State(initialValue: ChatViewModel(
            conversation: conversation,
            conversationStore: environment.conversationStore,
            messageStore: environment.messageStore,
            routingCoordinator: environment.routingCoordinator,
            providerRegistry: environment.providerRegistry,
            usageLimiter: environment.usageLimiter,
            settingsStore: environment.settingsStore
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.messages.isEmpty && !viewModel.isStreaming {
                ContentUnavailableView(
                    "Start the Conversation",
                    systemImage: "text.bubble",
                    description: Text("Type a message below — it'll be routed automatically to the local model or a cloud tier based on complexity.")
                )
                .frame(maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(viewModel.messages) { message in
                                MessageBubbleView(message: message, displayName: displayName)
                                    .id(message.id)
                            }
                            if viewModel.isStreaming {
                                HStack {
                                    Text(viewModel.streamingText)
                                        .padding(10)
                                        .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                                    Spacer(minLength: 40)
                                }
                                .id("streaming")
                            }
                        }
                        .padding()
                    }
                    .onChange(of: viewModel.messages.count) {
                        scrollToBottom(proxy: proxy)
                    }
                    .onChange(of: viewModel.streamingText) {
                        scrollToBottom(proxy: proxy)
                    }
                }
            }

            if viewModel.pendingSearchPermission {
                searchPermissionBanner
            }

            if let routingNote = viewModel.routingNote {
                Text(routingNote)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal)
            }

            if let usageWarning = viewModel.usageWarning {
                Text(usageWarning)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }

            Divider()

            MessageComposerView(
                text: $viewModel.draftText,
                isSending: viewModel.isStreaming,
                onSend: { Task { await viewModel.sendMessage() } }
            )
        }
        .navigationTitle(conversationTitle)
        .toolbar {
            ToolbarItem {
                Button {
                    webSearchEnabled.toggle()
                    settingsStore.saveWebSearchEnabled(webSearchEnabled)
                } label: {
                    Image(systemName: webSearchEnabled ? "globe" : "globe.desk.fill")
                }
                .help(webSearchEnabled ? "Web search: On" : "Web search: Off")
            }
        }
        .task {
            await viewModel.loadMessages()
        }
    }

    private var searchPermissionBanner: some View {
        HStack {
            Text("This needs web search but you're over budget — allow this one cloud call anyway?")
                .font(.caption)
            Spacer()
            Button("Deny") { Task { await viewModel.denySearchOverride() } }
                .buttonStyle(.plain)
            Button("Allow") { Task { await viewModel.allowSearchOverride() } }
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.15))
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        withAnimation {
            if viewModel.isStreaming {
                proxy.scrollTo("streaming", anchor: .bottom)
            } else if let lastID = viewModel.messages.last?.id {
                proxy.scrollTo(lastID, anchor: .bottom)
            }
        }
    }
}
```

Note: `"globe.desk.fill"` may not exist as an SF Symbol on this macOS version — if Step 2's build reports an invalid/missing symbol warning (SF Symbols degrade to a placeholder rather than failing the build, so watch the build log, not just the exit code), replace it with `"globe.slash"` or `"network.slash"`, whichever renders in Xcode's symbol picker on this system.

- [ ] **Step 2: Add the Sources disclosure to MessageBubbleView**

Replace the full contents of `AIChatRouter/Views/Chat/MessageBubbleView.swift`:

```swift
import SwiftUI
import AIChatRouterKit

struct MessageBubbleView: View {
    let message: Message
    let displayName: (String) -> String
    @State private var sourcesExpanded = false

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }
            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                Text(message.content)
                    .padding(10)
                    .background(bubbleColor, in: RoundedRectangle(cornerRadius: 12))
                if message.role == .assistant, let tier = message.tier {
                    ModelBadgeView(
                        tier: tier,
                        displayName: badgeDisplayName(for: tier),
                        tokenCount: totalTokens
                    )
                }
                if let citations = Message.decodeCitations(message.citationsJSON), !citations.isEmpty {
                    sourcesDisclosure(citations)
                }
            }
            if message.role != .user { Spacer(minLength: 40) }
        }
    }

    private func sourcesDisclosure(_ citations: [SearchCitation]) -> some View {
        DisclosureGroup(isExpanded: $sourcesExpanded) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(citations, id: \.url) { citation in
                    if let url = URL(string: citation.url) {
                        Link(citation.title ?? citation.url, destination: url)
                            .font(.caption2)
                            .lineLimit(1)
                    } else {
                        Text(citation.title ?? citation.url)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.top, 2)
        } label: {
            Text("Sources (\(citations.count))")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var bubbleColor: Color {
        message.role == .user ? Color.accentColor.opacity(0.85) : Color.secondary.opacity(0.15)
    }

    private var totalTokens: Int? {
        let total = (message.inputTokens ?? 0) + (message.outputTokens ?? 0)
        return total > 0 ? total : nil
    }

    private func badgeDisplayName(for tier: ModelTier) -> String {
        guard let modelID = message.modelID else {
            switch tier {
            case .local: return "Local"
            case .cloudFast: return "Cloud Fast"
            case .cloudAdvanced: return "Cloud Advanced"
            }
        }
        return displayName(modelID)
    }
}
```

Note the `URL(string: citation.url)` guard in `sourcesDisclosure` — this is the fix for the "malformed citation URL" review-focus item: a citation whose URL string doesn't parse falls back to plain (non-link) text instead of crashing via a force-unwrap.

- [ ] **Step 3: Build the app target**

Run: `cd .. && xcodegen generate && xcodebuild -scheme AIChatRouter -project AIChatRouter.xcodeproj -skipPackagePluginValidation build 2>&1 | grep -E "error:|BUILD SUCCEEDED"`
Expected: `BUILD SUCCEEDED`, no errors anywhere.

---

## Task 10: AppEnvironment wiring

**Files:**
- Modify: `AIChatRouter/Support/AppEnvironment.swift`

**Interfaces:**
- Consumes: `RoutingCoordinator.init(router:logStore:usageLimiter:networkStatus:settingsStore:)` (Task 3's new required parameter).

- [ ] **Step 1: Add the settingsStore parameter to the RoutingCoordinator construction**

In `AIChatRouter/Support/AppEnvironment.swift`, find:

```swift
        self.routingCoordinator = RoutingCoordinator(
            router: PromptedLocalQueryRouter(
                modelManager: localModelManager,
                modelID: LocalModelCatalog.default.id
            ),
            logStore: routingLogStore,
            usageLimiter: usageLimiter,
            networkStatus: NWPathMonitorNetworkStatus()
        )
```

Replace it with:

```swift
        self.routingCoordinator = RoutingCoordinator(
            router: PromptedLocalQueryRouter(
                modelManager: localModelManager,
                modelID: LocalModelCatalog.default.id
            ),
            logStore: routingLogStore,
            usageLimiter: usageLimiter,
            networkStatus: NWPathMonitorNetworkStatus(),
            settingsStore: settingsStore
        )
```

(`settingsStore` is already a stored property, initialized earlier in the same `init` — this just passes the existing instance through.)

- [ ] **Step 2: Build the full app**

Run: `cd .. && xcodegen generate && xcodebuild -scheme AIChatRouter -project AIChatRouter.xcodeproj -skipPackagePluginValidation build 2>&1 | grep -E "error:|BUILD SUCCEEDED"`
Expected: `BUILD SUCCEEDED`, zero errors.

- [ ] **Step 3: Run the full kit test suite one more time**

Run: `cd "AIChatRouterKit" && swift test 2>&1 | tail -5`
Expected: all tests pass (48 total).

---

## Task 11: Live app checkpoint

**Files:** none (verification only).

- [ ] **Step 1: Relaunch the app**

```bash
pkill -f "AIChatRouter.app/Contents/MacOS/AIChatRouter" 2>/dev/null
sleep 1
open -n "/Users/sayantanprojects/Library/Developer/Xcode/DerivedData/AIChatRouter-cbuqnompxwgdqkegmtmieiqqvytw/Build/Products/Debug/AIChatRouter.app"
sleep 2
pgrep -fl "AIChatRouter.app/Contents/MacOS/AIChatRouter" && echo RUNNING || echo CRASHED
```

Expected: RUNNING.

- [ ] **Step 2: Verify a search-needing query escalates and shows Sources**

In a conversation, send a query that clearly needs current info (e.g. "What is a notable tech headline today?"). Expected: the router should NOT answer locally — the badge should show a cloud model (Sonnet, assuming the default tier mapping), and a collapsed "Sources (N)" row should appear under the reply. Expand it and confirm the links are real, clickable URLs.

- [ ] **Step 3: Verify the global toggle suppresses search**

Click the globe toolbar icon to turn web search off (icon should change state). Send the same kind of current-info query again. Expected: no Sources row appears this time (it may still escalate to cloud based on complexity alone, but should not search).

Turn the toggle back on before continuing.

- [ ] **Step 4: Verify the caps-vs-search permission banner**

In Settings → Limits, set "Cloud Fast: max calls/day" to `0` (and leave Cloud Advanced uncapped, or also `0` to force the full cascade — either demonstrates the flag, but setting only Cloud Fast to `0` while Advanced is uncapped tests a single-step cascade, and setting both to `0` tests the two-step cascade this plan's Review Focus specifically calls out). Send a query that needs both search and escalates past Local (e.g. "Search for today's stock market news and give a detailed analysis"). Expected: instead of a normal reply, the orange "This needs web search but you're over budget" banner appears with Allow/Deny buttons.

Click **Allow**. Expected: the reply proceeds via a cloud model with search enabled (Sources row appears).

Repeat with a fresh query, click **Deny** this time. Expected: the reply proceeds via the local model, no search, no citations, no error — the conversation is not stuck.

Reset the Cloud Fast/Advanced caps back to blank (disabled) when done.

- [ ] **Step 5: Verify offline still forces local silently (no permission banner)**

Turn off Wi-Fi (or otherwise disconnect networking). Send a query that needs search. Expected: the orange offline banner appears ("You're offline — all responses will use the local model"), the reply comes from Local, and **no** Allow/Deny permission banner appears (offline never seeks permission, per this plan's Global Constraints). Reconnect networking afterward.

- [ ] **Step 6: Final full-suite confirmation**

```bash
cd "AIChatRouterKit" && swift test 2>&1 | tail -5
```

Expected: all tests pass, matching the count from Task 10 Step 3.
