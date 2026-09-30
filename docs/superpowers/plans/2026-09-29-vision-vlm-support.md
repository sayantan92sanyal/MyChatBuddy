# Vision/VLM Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user attach an image to a single chat message and get an answer from a local, on-device vision-language model (Qwen3-VL-8B-Thinking-4bit), while also making the existing (currently dead) local-model picker in Settings actually control which model runs, for both text and vision.

**Architecture:** A second local model slot (`ProviderID.localVLM`, loaded via MLXVLM's `VLMModelFactory` instead of MLXLLM's `LLMModelFactory`) is added alongside the existing local-text slot. `ChatTurn` gains an `images: [Data]` field so image bytes can ride on the same `LLMProvider` protocol without a signature change. Attaching an image to a message deterministically bypasses `RoutingCoordinator` and routes straight to the vision slot — the router, usage limiter, and search-permission logic are untouched. `ProviderRegistry` is rewritten so both local slots resolve their active model id live from `AppSettingsStore` on every call (closing the gap where the Settings picker never actually took effect), instead of a fixed descriptor captured once at launch.

**Tech Stack:** Swift 6, SwiftUI (macOS 14+), GRDB (SQLite), MLXLLM/MLXVLM/MLXLMCommon (`mlx-swift-lm`), Swift Testing (`@Test`/`#expect`).

**Spec:** `docs/superpowers/specs/2026-09-29-vision-vlm-support-design.md`

## Global Constraints

- Anthropic and OpenAI vision support are out of scope — this plan touches the local vision slot only.
- An image-bearing message bypasses `RoutingCoordinator`, `UsageLimiter`, and routing-log entirely — no exceptions, no partial application of any of that machinery.
- Image attachments are per-message only — never re-sent as context on later turns (unlike text attachments, which stay conversation-wide).
- Exactly one pending image per message in v1. If more than one image file is selected/dropped in a single action, the first is kept and the rest are reported via an explicit error — never silently dropped.
- Both local model catalogs (text and vision) stay curated, hardcoded lists — no arbitrary Hugging Face repo entry field.
- Images are downscaled so their longest edge is at most 1568px before persistence or inference; an oversized *source* file is rejected outright (before any downscale work) against a user-configurable byte cap.
- Switching the active local text or vision model in Settings must take effect on the very next message — no app restart.

## Review Focus

- Attaching an image when the vision model hasn't been downloaded yet must produce a clear, specific error pointing at Settings — never a silent hang or an attempt to auto-download a 5.4GB model mid-chat. (Task 12, step covering `isLocalModelReady`.)
- Switching the active local text or vision model in Settings must be reflected by the very next `resolve(tier: .local)` / `resolveVision()` call, with no restart — this is the actual dead-wiring bug being fixed, so it needs a direct test, not just code review. (Task 8.)
- Removing a pending image (the composer's × button) before sending must leave the next message's `ChatTurn.images` empty — no leftover image silently riding along on an unrelated text-only turn. (Task 12, `removePendingImage` test.)
- Attaching a normal document (e.g. a `.txt` or `.pdf`) via drag-and-drop must still work exactly as before after the image fork is added — a regression here would break an already-shipped feature silently. (Task 13, manual verification checklist.)
- A user with no vision model downloaded yet must still be able to pick and preview an image in the composer — the failure should surface at *send* time with a specific message, not block attaching or picking. (Task 12/13, manual verification checklist.)

---

## Task 1: Core protocol additions — `ChatTurn.images` and `ProviderID.localVLM`

**Files:**
- Modify: `AIChatRouterKit/Sources/AIChatRouterKit/Providers/LLMProvider.swift` (the `ChatTurn` struct, lines 17–31)
- Modify: `AIChatRouterKit/Sources/AIChatRouterKit/Models/ProviderID.swift`
- Test: `AIChatRouterKit/Tests/AIChatRouterKitTests/ChatTurnImagesTests.swift` (new)

**Interfaces:**
- Produces: `ChatTurn.init(role:content:images:)` with `images: [Data] = []` (existing two-arg call sites keep compiling unchanged); `ChatTurn.images: [Data]`; `ProviderID.localVLM` case.

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import AIChatRouterKit

@Suite("ChatTurn images field")
struct ChatTurnImagesTests {
    @Test func defaultsToAnEmptyImagesArray() {
        let turn = ChatTurn(role: .user, content: "hello")
        #expect(turn.images.isEmpty)
    }

    @Test func canBeConstructedWithImageData() {
        let data = Data([0x01, 0x02, 0x03])
        let turn = ChatTurn(role: .user, content: "what is this?", images: [data])
        #expect(turn.images == [data])
    }

    @Test func providerIDIncludesLocalVLM() {
        #expect(ProviderID.allCases.contains(.localVLM))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd AIChatRouterKit && swift test --filter ChatTurnImagesTests`
Expected: FAIL — `value of type 'ChatTurn' has no member 'images'` and `type 'ProviderID' has no member 'localVLM'`.

- [ ] **Step 3: Implement**

In `LLMProvider.swift`, replace the `ChatTurn` struct:

```swift
public struct ChatTurn: Sendable, Codable, Equatable {
    public enum Role: String, Codable, Sendable {
        case system
        case user
        case assistant
    }

    public let role: Role
    public let content: String
    /// Raw image bytes attached to this turn. Empty for every turn except the one
    /// a user attached an image to — images are per-message, never re-sent as
    /// context on later turns. Only a `.vision`-kind `LocalMLXProvider` reads this;
    /// every other provider ignores it, which is safe because attaching an image
    /// bypasses `RoutingCoordinator` entirely and routes straight to that provider.
    public let images: [Data]

    public init(role: Role, content: String, images: [Data] = []) {
        self.role = role
        self.content = content
        self.images = images
    }
}
```

In `ProviderID.swift`, add the new case:

```swift
public enum ProviderID: String, Codable, Sendable, CaseIterable {
    case localMLX
    case localVLM
    case anthropic
    case openAI
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd AIChatRouterKit && swift test --filter ChatTurnImagesTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Run the full kit test suite to confirm no regressions**

Run: `cd AIChatRouterKit && swift test`
Expected: PASS — existing two-argument `ChatTurn(role:content:)` call sites in `ContextWindowBuilder.swift`, `AnthropicProviderCitationParsingTests.swift`, `OpenAIProviderTests.swift`, and `ProviderStreamChunkCitationsTests.swift` all still compile against the new default parameter.

- [ ] **Step 6: Commit**

```bash
git add AIChatRouterKit/Sources/AIChatRouterKit/Providers/LLMProvider.swift AIChatRouterKit/Sources/AIChatRouterKit/Models/ProviderID.swift AIChatRouterKit/Tests/AIChatRouterKitTests/ChatTurnImagesTests.swift
git commit -m "feat: add ChatTurn.images and ProviderID.localVLM"
```

---

## Task 2: `LocalModelCatalog` gains a kind and a vision catalog

**Files:**
- Modify: `AIChatRouterKit/Sources/AIChatRouterKit/LocalModel/LocalModelCatalog.swift`
- Test: `AIChatRouterKit/Tests/AIChatRouterKitTests/LocalModelCatalogTests.swift` (new)

**Interfaces:**
- Consumes: nothing new.
- Produces: `LocalModelOption.ModelKind` (`.text`/`.vision`), `LocalModelOption.kind: ModelKind`, `LocalModelCatalog.textModels: [LocalModelOption]`, `LocalModelCatalog.visionModels: [LocalModelOption]`, `LocalModelCatalog.defaultText: LocalModelOption`, `LocalModelCatalog.defaultVision: LocalModelOption`. (Replaces the old `LocalModelCatalog.all`/`.default` — every call site is updated in this task.)

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import AIChatRouterKit

@Suite("LocalModelCatalog")
struct LocalModelCatalogTests {
    @Test func everyTextModelHasTextKind() {
        #expect(!LocalModelCatalog.textModels.isEmpty)
        #expect(LocalModelCatalog.textModels.allSatisfy { $0.kind == .text })
    }

    @Test func everyVisionModelHasVisionKind() {
        #expect(!LocalModelCatalog.visionModels.isEmpty)
        #expect(LocalModelCatalog.visionModels.allSatisfy { $0.kind == .vision })
    }

    @Test func defaultTextIsInTheTextCatalog() {
        #expect(LocalModelCatalog.textModels.contains(LocalModelCatalog.defaultText))
    }

    @Test func defaultVisionIsInTheVisionCatalog() {
        #expect(LocalModelCatalog.visionModels.contains(LocalModelCatalog.defaultVision))
    }

    @Test func visionCatalogIncludesTheVerifiedQwenModel() {
        #expect(LocalModelCatalog.visionModels.contains { $0.id == "mlx-community/Qwen3-VL-8B-Thinking-4bit" })
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd AIChatRouterKit && swift test --filter LocalModelCatalogTests`
Expected: FAIL — `type 'LocalModelCatalog' has no member 'textModels'` (and similar).

- [ ] **Step 3: Implement**

Replace the full contents of `LocalModelCatalog.swift`:

```swift
import Foundation

/// A local MLX model, identified by its Hugging Face repo id (e.g.
/// "mlx-community/Llama-3.2-3B-Instruct-4bit").
public struct LocalModelOption: Sendable, Identifiable, Hashable {
    /// Which MLX factory can load this model: `LLMModelFactory` (text) or
    /// `VLMModelFactory` (vision). Kept here, not inferred from the id, since
    /// nothing about a bare repo id string reveals which factory it needs.
    public enum ModelKind: Sendable {
        case text
        case vision
    }

    public let id: String
    public let displayName: String
    public let kind: ModelKind

    public init(id: String, displayName: String, kind: ModelKind) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
    }
}

/// Swappable catalogs of local MLX models, one per kind. Both stay curated,
/// hardcoded lists — no arbitrary Hugging Face repo entry — so every option is
/// guaranteed to actually load via its kind's factory.
public enum LocalModelCatalog {
    public static let llama3_2_3B = LocalModelOption(
        id: "mlx-community/Llama-3.2-3B-Instruct-4bit",
        displayName: "Llama 3.2 3B Instruct (4-bit)",
        kind: .text
    )
    public static let qwen2_5_3B = LocalModelOption(
        id: "mlx-community/Qwen2.5-3B-Instruct-4bit",
        displayName: "Qwen2.5 3B Instruct (4-bit)",
        kind: .text
    )
    public static let qwen2_5_7B = LocalModelOption(
        id: "mlx-community/Qwen2.5-7B-Instruct-4bit",
        displayName: "Qwen2.5 7B Instruct (4-bit)",
        kind: .text
    )
    public static let qwen3VL8BThinking = LocalModelOption(
        id: "mlx-community/Qwen3-VL-8B-Thinking-4bit",
        displayName: "Qwen3-VL 8B Thinking (4-bit)",
        kind: .vision
    )

    public static let textModels: [LocalModelOption] = [llama3_2_3B, qwen2_5_3B, qwen2_5_7B]
    public static let visionModels: [LocalModelOption] = [qwen3VL8BThinking]

    public static let defaultText = llama3_2_3B
    public static let defaultVision = qwen3VL8BThinking
}
```

- [ ] **Step 4: Run the new test to verify it passes**

Run: `cd AIChatRouterKit && swift test --filter LocalModelCatalogTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Fix every call site that used the old `.all`/`.default` API**

Run: `cd "/Users/sayantanprojects/Documents/AI app" && grep -rn "LocalModelCatalog\.\(all\|default\)\b" --include="*.swift" AIChatRouter AIChatRouterKit/Sources AIChatRouterKit/Tests`

This must list exactly:
- `AIChatRouter/ViewModels/LocalModelSettingsViewModel.swift:8` and `:9`
- `AIChatRouter/Support/AppEnvironment.swift:49`, `:57`, `:109`

Leave these as compile errors for now — `LocalModelSettingsViewModel` and `AppEnvironment` are rewritten in Tasks 10 and 9 respectively, which will replace every one of these references. Do not patch them here; the full package intentionally will not build again until Task 9 lands (Tasks 3–8 only touch `AIChatRouterKit`, which builds independently of the `AIChatRouter` app target — confirm this with the next step).

- [ ] **Step 6: Confirm the kit target itself still builds and tests pass in isolation**

Run: `cd AIChatRouterKit && swift build && swift test`
Expected: PASS — `AIChatRouterKit` does not depend on `AIChatRouter`, so the app target's now-broken references to `LocalModelCatalog.all`/`.default` do not affect this build.

- [ ] **Step 7: Commit**

```bash
git add AIChatRouterKit/Sources/AIChatRouterKit/LocalModel/LocalModelCatalog.swift AIChatRouterKit/Tests/AIChatRouterKitTests/LocalModelCatalogTests.swift
git commit -m "feat: split LocalModelCatalog into text and vision catalogs"
```

---

## Task 3: `LocalModelManager` dispatches to the right MLX factory by kind

**Files:**
- Modify: `AIChatRouterKit/Package.swift`
- Modify: `AIChatRouterKit/Sources/AIChatRouterKit/LocalModel/LocalModelManager.swift`
- Modify: `AIChatRouterKit/Sources/AIChatRouterKit/Router/PromptedLocalQueryRouter.swift:22`
- Modify: `AIChatRouterKit/Sources/AIChatRouterKit/Providers/LocalMLXProvider.swift:37` (minimal fix only — fully rewritten in Task 4)
- Test: `AIChatRouterKit/Tests/AIChatRouterKitTests/LocalModelManagerFactoryDispatchTests.swift` (new)

**Interfaces:**
- Consumes: `LocalModelOption.ModelKind` (Task 2).
- Produces: `LocalModelManager.loadedContainer(for modelID: String, kind: LocalModelOption.ModelKind, progressHandler:) async throws -> ModelContainer` (replaces the old two-parameter version — every call site updated in this task); `LocalModelManager.factory(for kind: LocalModelOption.ModelKind) -> any MLXLMCommon.ModelFactory` (internal, for testing).

- [ ] **Step 1: Add the MLXVLM product dependency**

In `AIChatRouterKit/Package.swift`, add `.library(name: "MLXVLM", targets: ["MLXVLM"])`'s product is already declared by the upstream package — only the *dependency* declarations need updating. Change the `AIChatRouterKit` target's dependencies to add `MLXVLM`, and add the same to the test target so `LocalModelManagerFactoryDispatchTests` can import it directly:

```swift
targets: [
    .target(
        name: "AIChatRouterKit",
        dependencies: [
            .product(name: "GRDB", package: "GRDB.swift"),
            .product(name: "MLXLLM", package: "mlx-swift-lm"),
            .product(name: "MLXVLM", package: "mlx-swift-lm"),
            .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            .product(name: "HuggingFace", package: "swift-huggingface"),
            .product(name: "Tokenizers", package: "swift-transformers")
        ]
    ),
    .testTarget(
        name: "AIChatRouterKitTests",
        dependencies: [
            "AIChatRouterKit",
            .product(name: "MLXLLM", package: "mlx-swift-lm"),
            .product(name: "MLXVLM", package: "mlx-swift-lm")
        ],
        resources: [.copy("Fixtures")]
    )
]
```

- [ ] **Step 2: Write the failing test**

```swift
import Testing
import MLXLLM
import MLXVLM
@testable import AIChatRouterKit

@Suite("LocalModelManager factory dispatch")
struct LocalModelManagerFactoryDispatchTests {
    @Test func textKindDispatchesToLLMModelFactory() {
        let factory = LocalModelManager.factory(for: .text)
        #expect(factory as AnyObject === LLMModelFactory.shared)
    }

    @Test func visionKindDispatchesToVLMModelFactory() {
        let factory = LocalModelManager.factory(for: .vision)
        #expect(factory as AnyObject === VLMModelFactory.shared)
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `cd AIChatRouterKit && swift test --filter LocalModelManagerFactoryDispatchTests`
Expected: FAIL to compile — `type 'LocalModelManager' has no member 'factory'`.

- [ ] **Step 4: Implement**

Replace `LocalModelManager.swift`:

```swift
import Foundation
import MLXLLM
import MLXVLM
import MLXLMCommon

/// Downloads (via `HubClientDownloader`, into the shared HF cache) and loads MLX models,
/// caching the resulting `ModelContainer` per model id for the lifetime of the app.
/// Serves both local slots (text via `LLMModelFactory`, vision via `VLMModelFactory`) —
/// both factories produce the same `ModelContainer` type, so one manager/cache serves
/// both; `kind` only selects which factory populates it.
public actor LocalModelManager {
    public enum ModelState: Sendable, Equatable {
        case notDownloaded
        case downloading(Double)
        case ready
        case failed(String)
    }

    private var containers: [String: ModelContainer] = [:]
    private var states: [String: ModelState] = [:]
    private let downloader: any Downloader
    private let tokenizerLoader: any TokenizerLoader

    public init(
        downloader: any Downloader = HubClientDownloader(),
        tokenizerLoader: any TokenizerLoader = TransformersTokenizerLoader()
    ) {
        self.downloader = downloader
        self.tokenizerLoader = tokenizerLoader
    }

    public func state(for modelID: String) -> ModelState {
        states[modelID] ?? .notDownloaded
    }

    /// Downloads/loads the given model if needed and returns its `ModelContainer`.
    /// Subsequent calls for the same model id return the cached container immediately.
    public func loadedContainer(
        for modelID: String,
        kind: LocalModelOption.ModelKind,
        progressHandler: @Sendable @escaping (Double) -> Void = { _ in }
    ) async throws -> ModelContainer {
        if let existing = containers[modelID] {
            return existing
        }

        states[modelID] = .downloading(0)
        do {
            let container = try await Self.factory(for: kind).loadContainer(
                from: downloader,
                using: tokenizerLoader,
                configuration: .init(id: modelID),
                progressHandler: { [weak self] progress in
                    let fraction = progress.fractionCompleted
                    progressHandler(fraction)
                    Task { await self?.recordProgress(modelID: modelID, fraction: fraction) }
                }
            )
            containers[modelID] = container
            states[modelID] = .ready
            return container
        } catch {
            states[modelID] = .failed(error.localizedDescription)
            throw error
        }
    }

    /// Pure dispatch, kept as a static func so it's testable by factory identity
    /// without needing a real download — `LLMModelFactory.shared`/`VLMModelFactory.shared`
    /// are both singletons of distinct final classes that produce the same
    /// `ModelContainer` type (verified against the vendored mlx-swift-lm package).
    static func factory(for kind: LocalModelOption.ModelKind) -> any ModelFactory {
        switch kind {
        case .text: return LLMModelFactory.shared
        case .vision: return VLMModelFactory.shared
        }
    }

    private func recordProgress(modelID: String, fraction: Double) {
        if case .ready = states[modelID] { return }
        states[modelID] = .downloading(fraction)
    }
}
```

Fix the one other kit-internal call site, `PromptedLocalQueryRouter.swift:22` — the query-classifier model is always a text model:

```swift
let container = try await modelManager.loadedContainer(for: modelID, kind: .text)
```

`LocalMLXProvider.swift:37` also calls `loadedContainer(for:)` and is in the same package target, so it must be patched too or the whole target fails to build. `LocalMLXProvider` doesn't have a `kind` property yet (that lands in Task 4, which rewrites this file properly) — for now, make the minimal fix that keeps every local model this provider currently serves working exactly as before: hardcode `kind: .text`, since every model `LocalMLXProvider` loads today is a text model.

```swift
let container = try await modelManager.loadedContainer(for: modelID, kind: .text)
```

- [ ] **Step 5: Run the new test to verify it passes**

Run: `cd AIChatRouterKit && swift test --filter LocalModelManagerFactoryDispatchTests`
Expected: PASS (2 tests).

- [ ] **Step 6: Run the full kit test suite**

Run: `cd AIChatRouterKit && swift build && swift test`
Expected: PASS, no compile errors anywhere in the target — both `loadedContainer(for:)` call sites (`PromptedLocalQueryRouter.swift`, `LocalMLXProvider.swift`) now pass `kind:`.

- [ ] **Step 7: Commit**

```bash
git add AIChatRouterKit/Package.swift AIChatRouterKit/Sources/AIChatRouterKit/LocalModel/LocalModelManager.swift AIChatRouterKit/Sources/AIChatRouterKit/Router/PromptedLocalQueryRouter.swift AIChatRouterKit/Sources/AIChatRouterKit/Providers/LocalMLXProvider.swift AIChatRouterKit/Tests/AIChatRouterKitTests/LocalModelManagerFactoryDispatchTests.swift
git commit -m "feat: dispatch LocalModelManager loads to LLMModelFactory or VLMModelFactory by kind"
```

---

## Task 4: `LocalMLXProvider` threads images through for vision-kind models

**Files:**
- Modify: `AIChatRouterKit/Sources/AIChatRouterKit/Providers/LocalMLXProvider.swift`
- Test: `AIChatRouterKit/Tests/AIChatRouterKitTests/LocalMLXProviderImageHandlingTests.swift` (new)

**Interfaces:**
- Consumes: `LocalModelManager.loadedContainer(for:kind:)` (Task 3), `ChatTurn.images` (Task 1), `LocalModelOption.ModelKind` (Task 2), `ProviderError.decodingFailed(String)` (existing).
- Produces: `LocalMLXProvider.init(modelManager:modelID:kind: LocalModelOption.ModelKind = .text)`; `LocalMLXProvider.id` now derived from `kind` (`.localMLX` for `.text`, `.localVLM` for `.vision`) instead of a fixed constant.

- [ ] **Step 1: Write the failing tests**

These use fakes that fail fast (no real network/model download), so they run instantly and deterministically. The vision-kind test proves image decoding happens *before* any model load is attempted (by using a `Downloader` that never reaches the real model-loading logic); the text-kind test proves a `.text`-kind provider never even inspects `images`.

```swift
import Foundation
import Testing
import MLXLMCommon
@testable import AIChatRouterKit

@Suite("LocalMLXProvider image handling")
struct LocalMLXProviderImageHandlingTests {
    private struct FailingDownloader: Downloader {
        struct Failure: Error {}
        func download(
            id: String, revision: String?, matching patterns: [String],
            useLatest: Bool, progressHandler: @Sendable @escaping (Progress) -> Void
        ) async throws -> URL {
            throw Failure()
        }
    }

    private struct UnreachableTokenizerLoader: TokenizerLoader {
        func load(from directory: URL) async throws -> any Tokenizer {
            fatalError("must not be reached in this test")
        }
    }

    private func makeManager() -> LocalModelManager {
        LocalModelManager(downloader: FailingDownloader(), tokenizerLoader: UnreachableTokenizerLoader())
    }

    @Test func visionKindThrowsDecodingFailedForUndecodableImageWithoutTouchingTheDownloader() async throws {
        let provider = LocalMLXProvider(modelManager: makeManager(), modelID: "any-id", kind: .vision)
        let turns = [ChatTurn(role: .user, content: "what is this?", images: [Data([0x00, 0x01, 0x02])])]
        let descriptor = ProviderModelDescriptor(id: "any-id", providerID: .localVLM, tier: .local, displayName: "Test Vision")
        let stream = provider.streamCompletion(
            model: descriptor, systemPrompt: nil, turns: turns, maxOutputTokens: 10, enableWebSearch: false
        )

        do {
            for try await _ in stream { Issue.record("Expected a thrown error") }
        } catch ProviderError.decodingFailed(let reason) {
            #expect(reason == "Could not decode attached image")
        } catch {
            Issue.record("Expected ProviderError.decodingFailed, got \(error)")
        }
    }

    @Test func textKindIgnoresTheImagesFieldAndProceedsToLoadTheModel() async throws {
        let provider = LocalMLXProvider(modelManager: makeManager(), modelID: "any-id", kind: .text)
        let turns = [ChatTurn(role: .user, content: "hi", images: [Data([0x00, 0x01, 0x02])])]
        let descriptor = ProviderModelDescriptor(id: "any-id", providerID: .localMLX, tier: .local, displayName: "Test Text")
        let stream = provider.streamCompletion(
            model: descriptor, systemPrompt: nil, turns: turns, maxOutputTokens: 10, enableWebSearch: false
        )

        do {
            for try await _ in stream { Issue.record("Expected a thrown error") }
        } catch is FailingDownloader.Failure {
            // Expected: the .text path skipped image decoding entirely and reached
            // the (fake, failing) download step instead.
        } catch {
            Issue.record("Expected FailingDownloader.Failure (proving images were never decoded), got \(error)")
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd AIChatRouterKit && swift test --filter LocalMLXProviderImageHandlingTests`
Expected: FAIL to compile — `LocalMLXProvider.init` has no `kind:` parameter yet (Task 3 only patched its internal `loadedContainer` call to hardcode `kind: .text`; it did not add a `kind` property to the type itself).

- [ ] **Step 3: Implement**

Replace `LocalMLXProvider.swift`:

```swift
import Foundation
import CoreImage
import MLXLMCommon

/// Runs completions on-device via MLX. Builds a fresh `ChatSession` re-primed with the
/// trimmed turn history on every call rather than holding a persistent session — simpler
/// for v1 and consistent with `LLMProvider` being otherwise stateless per call.
public struct LocalMLXProvider: LLMProvider, Sendable {
    public let id: ProviderID
    private let modelManager: LocalModelManager
    private let modelID: String
    private let kind: LocalModelOption.ModelKind

    public init(modelManager: LocalModelManager, modelID: String, kind: LocalModelOption.ModelKind = .text) {
        self.modelManager = modelManager
        self.modelID = modelID
        self.kind = kind
        self.id = kind == .vision ? .localVLM : .localMLX
    }

    public func isConfigured() async -> Bool {
        if case .ready = await modelManager.state(for: modelID) { return true }
        return false
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
                    guard let lastUserTurn = turns.last, lastUserTurn.role == .user else {
                        throw ProviderError.modelNotReady
                    }

                    // Decode before ever touching the model manager: a `.vision`-kind
                    // provider is only ever handed image data when the user actually
                    // attached one (routing bypass guarantees `.text`-kind turns are
                    // always empty here), so failing fast on bad image bytes avoids a
                    // pointless model load attempt.
                    let images: [UserInput.Image]
                    if kind == .vision {
                        images = try lastUserTurn.images.map { data in
                            guard let ciImage = CIImage(data: data) else {
                                throw ProviderError.decodingFailed("Could not decode attached image")
                            }
                            return .ciImage(ciImage)
                        }
                    } else {
                        images = []
                    }

                    let container = try await modelManager.loadedContainer(for: modelID, kind: kind)

                    let history: [Chat.Message] = turns.dropLast().map { turn in
                        switch turn.role {
                        case .system: return .system(turn.content)
                        case .user: return .user(turn.content)
                        case .assistant: return .assistant(turn.content)
                        }
                    }

                    let session = ChatSession(
                        container,
                        instructions: systemPrompt,
                        history: history,
                        generateParameters: GenerateParameters(
                            maxTokens: maxOutputTokens,
                            temperature: 0.7
                        )
                    )

                    let start = Date()
                    var promptTokens = 0
                    var completionTokens = 0
                    for try await generation in session.streamDetails(to: lastUserTurn.content, images: images) {
                        if let chunk = generation.chunk, !chunk.isEmpty {
                            continuation.yield(ProviderStreamChunk(deltaText: chunk))
                        }
                        if let info = generation.info {
                            promptTokens = info.promptTokenCount
                            completionTokens = info.generationTokenCount
                        }
                    }

                    let latencyMS = Int(Date().timeIntervalSince(start) * 1000)
                    continuation.yield(ProviderStreamChunk(
                        deltaText: "",
                        isFinal: true,
                        usage: TokenUsage(inputTokens: promptTokens, outputTokens: completionTokens),
                        latencyMS: latencyMS
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd AIChatRouterKit && swift test --filter LocalMLXProviderImageHandlingTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Run the full kit test suite**

Run: `cd AIChatRouterKit && swift build && swift test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add AIChatRouterKit/Sources/AIChatRouterKit/Providers/LocalMLXProvider.swift AIChatRouterKit/Tests/AIChatRouterKitTests/LocalMLXProviderImageHandlingTests.swift
git commit -m "feat: LocalMLXProvider threads image data into vision-kind completions"
```

---

## Task 5: `AppSettingsStore` gains active-model and image-size-cap settings

**Files:**
- Modify: `AIChatRouterKit/Sources/AIChatRouterKit/Config/AppSettingsStore.swift`
- Test: `AIChatRouterKit/Tests/AIChatRouterKitTests/AppSettingsStoreLocalModelSelectionTests.swift` (new)
- Test: `AIChatRouterKit/Tests/AIChatRouterKitTests/AppSettingsStoreImageAttachmentSizeCapTests.swift` (new)

**Interfaces:**
- Produces: `loadActiveLocalTextModelID(default:) -> String` / `saveActiveLocalTextModelID(_:)`; `loadActiveLocalVisionModelID(default:) -> String` / `saveActiveLocalVisionModelID(_:)`; `loadImageAttachmentSizeCapBytes() -> Int` / `saveImageAttachmentSizeCapBytes(_:)`; `AppSettingsStore.defaultImageAttachmentSizeCapBytes: Int`, `AppSettingsStore.maxImageAttachmentSizeCapBytes: Int`.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import AIChatRouterKit

@Suite("AppSettingsStore local model selection")
struct AppSettingsStoreLocalModelSelectionTests {
    private func makeStore() -> AppSettingsStore {
        AppSettingsStore(defaults: UserDefaults(suiteName: "AppSettingsStoreLocalModelSelectionTests-\(UUID().uuidString)")!)
    }

    @Test func textModelIDDefaultsToTheGivenFallback() {
        let store = makeStore()
        #expect(store.loadActiveLocalTextModelID(default: "fallback-text") == "fallback-text")
    }

    @Test func textModelIDPersistsACustomValue() {
        let store = makeStore()
        store.saveActiveLocalTextModelID("mlx-community/Qwen2.5-7B-Instruct-4bit")
        #expect(store.loadActiveLocalTextModelID(default: "fallback-text") == "mlx-community/Qwen2.5-7B-Instruct-4bit")
    }

    @Test func visionModelIDDefaultsToTheGivenFallback() {
        let store = makeStore()
        #expect(store.loadActiveLocalVisionModelID(default: "fallback-vision") == "fallback-vision")
    }

    @Test func visionModelIDPersistsACustomValue() {
        let store = makeStore()
        store.saveActiveLocalVisionModelID("mlx-community/Qwen3-VL-8B-Thinking-4bit")
        #expect(store.loadActiveLocalVisionModelID(default: "fallback-vision") == "mlx-community/Qwen3-VL-8B-Thinking-4bit")
    }
}
```

```swift
import Foundation
import Testing
@testable import AIChatRouterKit

@Suite("AppSettingsStore image attachment size cap")
struct AppSettingsStoreImageAttachmentSizeCapTests {
    private func makeStore() -> AppSettingsStore {
        AppSettingsStore(defaults: UserDefaults(suiteName: "AppSettingsStoreImageAttachmentSizeCapTests-\(UUID().uuidString)")!)
    }

    @Test func defaultsToTheBuiltInDefault() {
        let store = makeStore()
        #expect(store.loadImageAttachmentSizeCapBytes() == AppSettingsStore.defaultImageAttachmentSizeCapBytes)
    }

    @Test func persistsACustomValue() {
        let store = makeStore()
        store.saveImageAttachmentSizeCapBytes(5_000_000)
        #expect(store.loadImageAttachmentSizeCapBytes() == 5_000_000)
    }

    @Test func zeroOrNegativeSavedValueFallsBackToDefault() {
        let store = makeStore()
        store.saveImageAttachmentSizeCapBytes(0)
        #expect(store.loadImageAttachmentSizeCapBytes() == AppSettingsStore.defaultImageAttachmentSizeCapBytes)
    }

    @Test func saveClampsToTheMaximumAllowedValue() {
        let store = makeStore()
        store.saveImageAttachmentSizeCapBytes(AppSettingsStore.maxImageAttachmentSizeCapBytes + 1_000_000)
        #expect(store.loadImageAttachmentSizeCapBytes() == AppSettingsStore.maxImageAttachmentSizeCapBytes)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd AIChatRouterKit && swift test --filter AppSettingsStoreLocalModelSelectionTests && swift test --filter AppSettingsStoreImageAttachmentSizeCapTests`
Expected: FAIL to compile — none of the new methods/constants exist yet.

- [ ] **Step 3: Implement**

In `AppSettingsStore.swift`, add three new private keys alongside the existing ones, and the new methods/constants at the end of the struct:

```swift
private let activeLocalTextModelIDKey = "com.sayantan.aichatrouter.activeLocalTextModelID"
private let activeLocalVisionModelIDKey = "com.sayantan.aichatrouter.activeLocalVisionModelID"
private let imageAttachmentSizeCapKey = "com.sayantan.aichatrouter.imageAttachmentSizeCapBytes"
```

```swift
    public func loadActiveLocalTextModelID(default defaultID: String) -> String {
        defaults.string(forKey: activeLocalTextModelIDKey) ?? defaultID
    }

    public func saveActiveLocalTextModelID(_ id: String) {
        defaults.set(id, forKey: activeLocalTextModelIDKey)
    }

    public func loadActiveLocalVisionModelID(default defaultID: String) -> String {
        defaults.string(forKey: activeLocalVisionModelIDKey) ?? defaultID
    }

    public func saveActiveLocalVisionModelID(_ id: String) {
        defaults.set(id, forKey: activeLocalVisionModelIDKey)
    }

    /// Ceiling on the *source* image file, checked before any downscaling —
    /// downscaling still costs CPU/memory proportional to the source size, so this
    /// guards against an absurdly large file (e.g. an uncompressed RAW photo) before
    /// that work even starts. 10MB comfortably covers real photos from any modern
    /// camera or screenshot.
    public static let defaultImageAttachmentSizeCapBytes = 10_000_000
    public static let maxImageAttachmentSizeCapBytes = 50_000_000

    public func loadImageAttachmentSizeCapBytes() -> Int {
        let value = defaults.integer(forKey: imageAttachmentSizeCapKey)
        return value > 0 ? value : Self.defaultImageAttachmentSizeCapBytes
    }

    public func saveImageAttachmentSizeCapBytes(_ value: Int) {
        let clamped = min(value, Self.maxImageAttachmentSizeCapBytes)
        defaults.set(clamped, forKey: imageAttachmentSizeCapKey)
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd AIChatRouterKit && swift test --filter AppSettingsStoreLocalModelSelectionTests && swift test --filter AppSettingsStoreImageAttachmentSizeCapTests`
Expected: PASS (4 + 4 tests).

- [ ] **Step 5: Run the full kit test suite**

Run: `cd AIChatRouterKit && swift build && swift test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add AIChatRouterKit/Sources/AIChatRouterKit/Config/AppSettingsStore.swift AIChatRouterKit/Tests/AIChatRouterKitTests/AppSettingsStoreLocalModelSelectionTests.swift AIChatRouterKit/Tests/AIChatRouterKitTests/AppSettingsStoreImageAttachmentSizeCapTests.swift
git commit -m "feat: persist active local text/vision model selection and image size cap"
```

---

## Task 6: `ImageDownscaler`

**Files:**
- Create: `AIChatRouterKit/Sources/AIChatRouterKit/Attachments/ImageDownscaler.swift`
- Test: `AIChatRouterKit/Tests/AIChatRouterKitTests/ImageDownscalerTests.swift` (new)

**Interfaces:**
- Produces: `ImageDownscaler.init()`, `ImageDownscaler.downscale(_ data: Data, maxLongestEdge: CGFloat = ImageDownscaler.maxLongestEdge) -> Data?`, `ImageDownscaler.maxLongestEdge: CGFloat` (1568).

- [ ] **Step 1: Write the failing tests**

Tests synthesize their own image data in memory (a solid-color bitmap) rather than relying on a checked-in binary fixture — no new fixture file is needed.

```swift
import AppKit
import Testing
@testable import AIChatRouterKit

@Suite("ImageDownscaler")
struct ImageDownscalerTests {
    private func makeSolidColorPNGData(width: Int, height: Int) -> Data {
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        image.unlockFocus()
        let tiff = image.tiffRepresentation!
        let rep = NSBitmapImageRep(data: tiff)!
        return rep.representation(using: .png, properties: [:])!
    }

    @Test func imagesUnderTheLimitAreReturnedUnchanged() {
        let data = makeSolidColorPNGData(width: 100, height: 100)
        let result = ImageDownscaler().downscale(data, maxLongestEdge: 1568)
        #expect(result == data)
    }

    @Test func imagesExactlyAtTheLimitAreReturnedUnchanged() {
        // Boundary check: longest edge == limit must NOT count as "over" it.
        let data = makeSolidColorPNGData(width: 1568, height: 800)
        let result = ImageDownscaler().downscale(data, maxLongestEdge: 1568)
        #expect(result == data)
    }

    @Test func imagesOverTheLimitAreResizedSoTheLongestEdgeFitsIt() {
        let data = makeSolidColorPNGData(width: 3000, height: 1500)
        guard let result = ImageDownscaler().downscale(data, maxLongestEdge: 1000) else {
            Issue.record("Expected a non-nil downscaled result")
            return
        }
        guard let resized = NSImage(data: result), let rep = resized.representations.first else {
            Issue.record("Expected the result to decode back into an image")
            return
        }
        #expect(rep.pixelsWide <= 1000)
        #expect(rep.pixelsHigh <= 1000)
        // Aspect ratio preserved (3000:1500 == 2:1 source, within rounding).
        #expect(abs(Double(rep.pixelsWide) / Double(rep.pixelsHigh) - 2.0) < 0.05)
    }

    @Test func undecodableDataReturnsNil() {
        let garbage = Data([0x00, 0x01, 0x02, 0x03])
        #expect(ImageDownscaler().downscale(garbage) == nil)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd AIChatRouterKit && swift test --filter ImageDownscalerTests`
Expected: FAIL — no such type `ImageDownscaler`.

- [ ] **Step 3: Implement**

```swift
import AppKit

/// Downscales an attached image so its longest edge fits within a maximum before
/// it's persisted or sent for inference — keeps stored blobs small and matches
/// what the vision model needs regardless. Returns the original data unchanged
/// when it's already within the limit (never re-encodes unnecessarily), and
/// `nil` if the data doesn't decode as an image at all.
public struct ImageDownscaler: Sendable {
    public static let maxLongestEdge: CGFloat = 1568

    public init() {}

    public func downscale(_ data: Data, maxLongestEdge: CGFloat = Self.maxLongestEdge) -> Data? {
        guard let image = NSImage(data: data) else { return nil }
        let size = image.size
        let longestEdge = max(size.width, size.height)
        guard longestEdge > maxLongestEdge else { return data }

        let scale = maxLongestEdge / longestEdge
        let newSize = NSSize(width: size.width * scale, height: size.height * scale)

        let resized = NSImage(size: newSize)
        resized.lockFocus()
        image.draw(
            in: NSRect(origin: .zero, size: newSize),
            from: NSRect(origin: .zero, size: size),
            operation: .copy,
            fraction: 1.0
        )
        resized.unlockFocus()

        guard let tiff = resized.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd AIChatRouterKit && swift test --filter ImageDownscalerTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Run the full kit test suite**

Run: `cd AIChatRouterKit && swift build && swift test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add AIChatRouterKit/Sources/AIChatRouterKit/Attachments/ImageDownscaler.swift AIChatRouterKit/Tests/AIChatRouterKitTests/ImageDownscalerTests.swift
git commit -m "feat: add ImageDownscaler"
```

---

## Task 7: `ImageAttachment` model, migration, and store

**Files:**
- Create: `AIChatRouterKit/Sources/AIChatRouterKit/Models/ImageAttachment.swift`
- Create: `AIChatRouterKit/Sources/AIChatRouterKit/Persistence/ImageAttachmentStore.swift`
- Modify: `AIChatRouterKit/Sources/AIChatRouterKit/Persistence/AppDatabase.swift` (add migration `v4`)
- Test: `AIChatRouterKit/Tests/AIChatRouterKitTests/ImageAttachmentStoreTests.swift` (new)

**Interfaces:**
- Consumes: `AppDatabase`, `ConversationStore`, `MessageStore` (existing).
- Produces: `ImageAttachment` (`id, conversationID, messageID, filename, imageData, sizeBytes, createdAt`), `ImageAttachmentStore.append(_:) async throws`, `ImageAttachmentStore.images(for conversationID:) async throws -> [ImageAttachment]`, `ImageAttachmentStore.delete(id:) async throws`.

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import AIChatRouterKit

@Suite("ImageAttachmentStore")
struct ImageAttachmentStoreTests {
    @Test func appendFetchAndDeleteRoundTrip() async throws {
        let db = try AppDatabase.openInMemory()
        let conversations = ConversationStore(database: db)
        let messages = MessageStore(database: db)
        let images = ImageAttachmentStore(database: db)

        let conversation = Conversation(title: "Image Test")
        try await conversations.create(conversation)
        let message = Message(conversationID: conversation.id, role: .user, content: "what's in this photo?")
        try await messages.append(message)

        let image = ImageAttachment(
            conversationID: conversation.id,
            messageID: message.id,
            filename: "photo.png",
            imageData: Data([0x01, 0x02, 0x03]),
            sizeBytes: 3
        )
        try await images.append(image)

        let fetched = try await images.images(for: conversation.id)
        #expect(fetched.count == 1)
        #expect(fetched.first?.filename == "photo.png")
        #expect(fetched.first?.messageID == message.id)
        #expect(fetched.first?.imageData == Data([0x01, 0x02, 0x03]))

        try await images.delete(id: image.id)
        let afterDelete = try await images.images(for: conversation.id)
        #expect(afterDelete.isEmpty)
    }

    @Test func deletingConversationCascadesImageAttachments() async throws {
        let db = try AppDatabase.openInMemory()
        let conversations = ConversationStore(database: db)
        let messages = MessageStore(database: db)
        let images = ImageAttachmentStore(database: db)

        let conversation = Conversation(title: "To Delete")
        try await conversations.create(conversation)
        let message = Message(conversationID: conversation.id, role: .user, content: "hi")
        try await messages.append(message)
        try await images.append(ImageAttachment(
            conversationID: conversation.id,
            messageID: message.id,
            filename: "a.png",
            imageData: Data([0x00]),
            sizeBytes: 1
        ))

        try await conversations.delete(id: conversation.id)

        let remaining = try await images.images(for: conversation.id)
        #expect(remaining.isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd AIChatRouterKit && swift test --filter ImageAttachmentStoreTests`
Expected: FAIL to compile — no such type `ImageAttachment`/`ImageAttachmentStore`, and no `image_attachment` table.

- [ ] **Step 3: Implement the model**

```swift
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
```

- [ ] **Step 4: Implement the migration**

In `AppDatabase.swift`, add a new migration after `"v3"`, before `return migrator`:

```swift
        migrator.registerMigration("v4") { db in
            try db.create(table: "image_attachment") { t in
                t.column("id", .blob).primaryKey()
                t.column("conversationID", .blob).notNull()
                    .references("conversation", onDelete: .cascade)
                t.column("messageID", .blob).notNull()
                    .references("message", onDelete: .cascade)
                t.column("filename", .text).notNull()
                t.column("imageData", .blob).notNull()
                t.column("sizeBytes", .integer).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(
                index: "idx_image_attachment_conversation",
                on: "image_attachment",
                columns: ["conversationID"]
            )
            try db.create(
                index: "idx_image_attachment_message",
                on: "image_attachment",
                columns: ["messageID"]
            )
        }
```

- [ ] **Step 5: Implement the store**

```swift
import Foundation
import GRDB

public struct ImageAttachmentStore: Sendable {
    private let dbQueue: DatabaseQueue

    public init(database: AppDatabase) {
        self.dbQueue = database.dbQueue
    }

    public func append(_ image: ImageAttachment) async throws {
        try await dbQueue.write { db in try image.insert(db) }
    }

    public func images(for conversationID: UUID) async throws -> [ImageAttachment] {
        try await dbQueue.read { db in
            try ImageAttachment
                .filter(Column("conversationID") == conversationID)
                .order(Column("createdAt"))
                .fetchAll(db)
        }
    }

    public func delete(id: UUID) async throws {
        _ = try await dbQueue.write { db in try ImageAttachment.deleteOne(db, key: id) }
    }
}
```

- [ ] **Step 6: Run test to verify it passes**

Run: `cd AIChatRouterKit && swift test --filter ImageAttachmentStoreTests`
Expected: PASS (2 tests).

- [ ] **Step 7: Run the full kit test suite**

Run: `cd AIChatRouterKit && swift build && swift test`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add AIChatRouterKit/Sources/AIChatRouterKit/Models/ImageAttachment.swift AIChatRouterKit/Sources/AIChatRouterKit/Persistence/ImageAttachmentStore.swift AIChatRouterKit/Sources/AIChatRouterKit/Persistence/AppDatabase.swift AIChatRouterKit/Tests/AIChatRouterKitTests/ImageAttachmentStoreTests.swift
git commit -m "feat: add ImageAttachment persistence"
```

---

## Task 8: `ProviderRegistry` rewrite — live local model resolution for both slots

This is the actual fix for the dead-wiring gap: today `.local` always resolves to whatever descriptor `AppEnvironment` captured once at launch, because `LocalMLXProvider` bakes its `modelID` in at construction and `ProviderRegistry` only ever holds one pre-built instance of it. The fix constructs a fresh `LocalMLXProvider` per `resolve`/`resolveVision` call, with the model id read live from `AppSettingsStore` — exactly how cloud tier resolution already works.

**Files:**
- Modify: `AIChatRouterKit/Sources/AIChatRouterKit/Providers/ProviderRegistry.swift`
- Test: `AIChatRouterKit/Tests/AIChatRouterKitTests/ProviderRegistryTests.swift` (new)

**Interfaces:**
- Consumes: `AppSettingsStore.loadActiveLocalTextModelID(default:)`/`loadActiveLocalVisionModelID(default:)` (Task 5), `LocalModelManager.state(for:)` (existing), `LocalMLXProvider.init(modelManager:modelID:kind:)` (Task 4), `LocalModelCatalog.textModels`/`.visionModels` (Task 2).
- Produces: `ProviderRegistry.init(cloudProviders:localModelManager:settingsStore:defaultTierModelMapping:defaultLocalTextModel:defaultLocalVisionModel:)` (replaces the old `init(providers:localDescriptor:settingsStore:defaultTierModelMapping:)`); `resolve(tier:) -> (provider: LLMProvider, descriptor: ProviderModelDescriptor)?` (same signature, new local-tier behavior); `resolveVision() -> (provider: LLMProvider, descriptor: ProviderModelDescriptor)` (new, non-optional — the vision slot is always constructible, unlike a cloud tier that can have no mapped provider); `isLocalModelReady(kind: LocalModelOption.ModelKind) async -> Bool` (new).

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import AIChatRouterKit

@Suite("ProviderRegistry")
struct ProviderRegistryTests {
    private let textA = LocalModelOption(id: "text-a", displayName: "Text A", kind: .text)
    private let textB = LocalModelOption(id: "text-b", displayName: "Text B", kind: .text)
    private let visionA = LocalModelOption(id: "vision-a", displayName: "Vision A", kind: .vision)

    private func makeSettingsStore() -> AppSettingsStore {
        AppSettingsStore(defaults: UserDefaults(suiteName: "ProviderRegistryTests-\(UUID().uuidString)")!)
    }

    private func makeRegistry(settingsStore: AppSettingsStore) -> ProviderRegistry {
        let mapping = TierModelMapping(
            cloudFast: ProviderModelDescriptor(id: "claude-sonnet-4-5", providerID: .anthropic, tier: .cloudFast, displayName: "Sonnet"),
            cloudAdvanced: ProviderModelDescriptor(id: "claude-opus-4-1", providerID: .anthropic, tier: .cloudAdvanced, displayName: "Opus")
        )
        return ProviderRegistry(
            cloudProviders: [.anthropic: AnthropicProvider()],
            localModelManager: LocalModelManager(),
            settingsStore: settingsStore,
            defaultTierModelMapping: mapping,
            defaultLocalTextModel: textA,
            defaultLocalVisionModel: visionA
        )
    }

    @Test func localTierResolvesToTheDefaultTextModelWhenNothingIsSaved() {
        let registry = makeRegistry(settingsStore: makeSettingsStore())
        let resolved = registry.resolve(tier: .local)
        #expect(resolved?.descriptor.id == "text-a")
        #expect(resolved?.descriptor.providerID == .localMLX)
    }

    @Test func localTierResolvesToTheSavedActiveTextModelAfterSwitching() {
        // The actual dead-wiring fix: switching the setting must be reflected on
        // the very next resolve() call, no restart required.
        let store = makeSettingsStore()
        let registry = makeRegistry(settingsStore: store)
        store.saveActiveLocalTextModelID("text-b")

        let resolved = registry.resolve(tier: .local)
        #expect(resolved?.descriptor.id == "text-b")
    }

    @Test func resolveVisionResolvesToTheDefaultVisionModelWhenNothingIsSaved() {
        let registry = makeRegistry(settingsStore: makeSettingsStore())
        let resolved = registry.resolveVision()
        #expect(resolved.descriptor.id == "vision-a")
        #expect(resolved.descriptor.providerID == .localVLM)
    }

    @Test func resolveVisionResolvesToTheSavedActiveVisionModelAfterSwitching() {
        let store = makeSettingsStore()
        let registry = makeRegistry(settingsStore: store)
        store.saveActiveLocalVisionModelID("vision-b")

        let resolved = registry.resolveVision()
        #expect(resolved.descriptor.id == "vision-b")
    }

    @Test func cloudTierResolutionIsUnaffectedByTheLocalRewrite() {
        let registry = makeRegistry(settingsStore: makeSettingsStore())
        let resolved = registry.resolve(tier: .cloudFast)
        #expect(resolved?.descriptor.id == "claude-sonnet-4-5")
        #expect(resolved?.descriptor.providerID == .anthropic)
    }

    @Test func isLocalModelReadyIsFalseForAModelThatHasNeverBeenLoaded() async {
        let registry = makeRegistry(settingsStore: makeSettingsStore())
        #expect(await registry.isLocalModelReady(kind: .vision) == false)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd AIChatRouterKit && swift test --filter ProviderRegistryTests`
Expected: FAIL to compile — old `ProviderRegistry.init(providers:localDescriptor:...)` signature doesn't match, `resolveVision`/`isLocalModelReady` don't exist.

- [ ] **Step 3: Implement**

Replace `ProviderRegistry.swift`:

```swift
import Foundation

/// Resolves a `ModelTier` (the only thing `QueryRouter` ever outputs) to a concrete
/// provider + model, keeping the router itself provider-agnostic. Reads the current
/// `TierModelMapping` and the active local text/vision model ids from `AppSettingsStore`
/// on every call, so Settings changes take effect immediately without needing to
/// reconstruct this registry or restart the app.
///
/// The local slots are handled separately from `cloudProviders`: `LocalMLXProvider`
/// bakes its model id into a stored property at construction (unlike the cloud
/// providers, which take their model id as a `streamCompletion` parameter), so a
/// fresh instance is constructed on every resolve call with whichever model id is
/// currently active — cheap, since `LocalModelManager` (a shared actor) caches the
/// expensive part (the loaded `ModelContainer`) by model id internally.
public struct ProviderRegistry: Sendable {
    private let cloudProviders: [ProviderID: LLMProvider]
    private let localModelManager: LocalModelManager
    private let settingsStore: AppSettingsStore
    private let defaultTierModelMapping: TierModelMapping
    private let defaultLocalTextModel: LocalModelOption
    private let defaultLocalVisionModel: LocalModelOption

    public init(
        cloudProviders: [ProviderID: LLMProvider],
        localModelManager: LocalModelManager,
        settingsStore: AppSettingsStore,
        defaultTierModelMapping: TierModelMapping,
        defaultLocalTextModel: LocalModelOption,
        defaultLocalVisionModel: LocalModelOption
    ) {
        self.cloudProviders = cloudProviders
        self.localModelManager = localModelManager
        self.settingsStore = settingsStore
        self.defaultTierModelMapping = defaultTierModelMapping
        self.defaultLocalTextModel = defaultLocalTextModel
        self.defaultLocalVisionModel = defaultLocalVisionModel
    }

    public func resolve(tier: ModelTier) -> (provider: LLMProvider, descriptor: ProviderModelDescriptor)? {
        switch tier {
        case .local:
            let modelID = settingsStore.loadActiveLocalTextModelID(default: defaultLocalTextModel.id)
            let displayName = LocalModelCatalog.textModels.first(where: { $0.id == modelID })?.displayName
                ?? defaultLocalTextModel.displayName
            let provider = LocalMLXProvider(modelManager: localModelManager, modelID: modelID, kind: .text)
            let descriptor = ProviderModelDescriptor(id: modelID, providerID: .localMLX, tier: .local, displayName: displayName)
            return (provider, descriptor)
        case .cloudFast:
            let mapping = settingsStore.loadTierModelMapping(default: defaultTierModelMapping)
            guard let provider = cloudProviders[mapping.cloudFast.providerID] else { return nil }
            return (provider, mapping.cloudFast)
        case .cloudAdvanced:
            let mapping = settingsStore.loadTierModelMapping(default: defaultTierModelMapping)
            guard let provider = cloudProviders[mapping.cloudAdvanced.providerID] else { return nil }
            return (provider, mapping.cloudAdvanced)
        }
    }

    /// Resolves the dedicated local vision slot — never part of `resolve(tier:)`
    /// since attaching an image bypasses tier routing entirely (see
    /// `ChatViewModel.sendMessage`). Always succeeds: unlike a cloud tier, there's
    /// no configuration under which the vision slot has no provider at all.
    public func resolveVision() -> (provider: LLMProvider, descriptor: ProviderModelDescriptor) {
        let modelID = settingsStore.loadActiveLocalVisionModelID(default: defaultLocalVisionModel.id)
        let displayName = LocalModelCatalog.visionModels.first(where: { $0.id == modelID })?.displayName
            ?? defaultLocalVisionModel.displayName
        let provider = LocalMLXProvider(modelManager: localModelManager, modelID: modelID, kind: .vision)
        let descriptor = ProviderModelDescriptor(id: modelID, providerID: .localVLM, tier: .local, displayName: displayName)
        return (provider, descriptor)
    }

    /// Whether the currently-active model for the given kind has finished
    /// downloading and loading. Used to fail fast with a clear message rather than
    /// triggering a multi-GB download mid-chat (see `ChatViewModel.sendMessage`).
    public func isLocalModelReady(kind: LocalModelOption.ModelKind) async -> Bool {
        let modelID: String
        switch kind {
        case .text: modelID = settingsStore.loadActiveLocalTextModelID(default: defaultLocalTextModel.id)
        case .vision: modelID = settingsStore.loadActiveLocalVisionModelID(default: defaultLocalVisionModel.id)
        }
        if case .ready = await localModelManager.state(for: modelID) { return true }
        return false
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd AIChatRouterKit && swift test --filter ProviderRegistryTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Run the full kit test suite**

Run: `cd AIChatRouterKit && swift build && swift test`
Expected: PASS. `AIChatRouterKit` now builds and tests fully green in isolation; `AIChatRouter` (the app target) will not compile again until Task 9.

- [ ] **Step 6: Commit**

```bash
git add AIChatRouterKit/Sources/AIChatRouterKit/Providers/ProviderRegistry.swift AIChatRouterKit/Tests/AIChatRouterKitTests/ProviderRegistryTests.swift
git commit -m "fix: resolve local text/vision models live from settings instead of a fixed launch-time descriptor"
```

---

## Task 9: `AppEnvironment` rewrite

No automated test — `AIChatRouter` (the app target) has no test suite (a pre-existing gap; see spec). This task's deliverable is a successful `xcodebuild build` plus a manual smoke check.

**Files:**
- Modify: `AIChatRouter/Support/AppEnvironment.swift`

**Interfaces:**
- Consumes: `ProviderRegistry.init(cloudProviders:localModelManager:settingsStore:defaultTierModelMapping:defaultLocalTextModel:defaultLocalVisionModel:)` (Task 8), `ImageAttachmentStore.init(database:)` (Task 7), `LocalModelCatalog.defaultText`/`.defaultVision` (Task 2).
- Produces: `AppEnvironment.imageAttachmentStore: ImageAttachmentStore` (new); `AppEnvironment.displayName(forModelID:)` now checks both local catalogs, not a single fixed descriptor. Removes `AppEnvironment.providers` and `.localDescriptor` (no longer needed — `ProviderRegistry` builds local providers on demand).

- [ ] **Step 1: Implement**

Replace `AppEnvironment.swift`:

```swift
import Foundation
import AIChatRouterKit

/// A selectable (provider, model) pair for one cloud tier, offered in
/// `TierProviderMappingView`. Model IDs are placeholders — Phase 7 makes these
/// user-editable in Settings rather than hardcoded, since provider lineups/pricing
/// change frequently.
struct TierProviderOption: Identifiable, Hashable {
    let id: String
    let descriptor: ProviderModelDescriptor
}

@MainActor
final class AppEnvironment {
    let database: AppDatabase
    let conversationStore: ConversationStore
    let messageStore: MessageStore
    let routingLogStore: RoutingLogStore
    let usageStore: UsageStore
    let attachmentStore: AttachmentStore
    let imageAttachmentStore: ImageAttachmentStore

    let localModelManager: LocalModelManager
    let settingsStore: AppSettingsStore

    let cloudFastOptions: [TierProviderOption]
    let cloudAdvancedOptions: [TierProviderOption]
    let defaultTierModelMapping: TierModelMapping

    let providerRegistry: ProviderRegistry
    let routingCoordinator: RoutingCoordinator
    let usageLimiter: UsageLimiter
    let networkStatusMonitor: NetworkStatusMonitor

    init(database: AppDatabase) {
        self.database = database
        self.conversationStore = ConversationStore(database: database)
        self.messageStore = MessageStore(database: database)
        self.routingLogStore = RoutingLogStore(database: database)
        self.usageStore = UsageStore(database: database)
        self.attachmentStore = AttachmentStore(database: database)
        self.imageAttachmentStore = ImageAttachmentStore(database: database)
        self.settingsStore = AppSettingsStore()

        let localModelManager = LocalModelManager()
        self.localModelManager = localModelManager

        let cloudProviders: [ProviderID: LLMProvider] = [
            .anthropic: AnthropicProvider(),
            .openAI: OpenAIProvider()
        ]

        self.cloudFastOptions = [
            TierProviderOption(
                id: "anthropic-sonnet",
                descriptor: ProviderModelDescriptor(
                    id: "claude-sonnet-4-5", providerID: .anthropic, tier: .cloudFast, displayName: "Sonnet"
                )
            ),
            TierProviderOption(
                id: "openai-gpt4o-mini",
                descriptor: ProviderModelDescriptor(
                    id: "gpt-4o-mini", providerID: .openAI, tier: .cloudFast, displayName: "GPT-4o mini"
                )
            )
        ]
        self.cloudAdvancedOptions = [
            TierProviderOption(
                id: "anthropic-opus",
                descriptor: ProviderModelDescriptor(
                    id: "claude-opus-4-1", providerID: .anthropic, tier: .cloudAdvanced, displayName: "Opus"
                )
            ),
            TierProviderOption(
                id: "openai-gpt4o",
                descriptor: ProviderModelDescriptor(
                    id: "gpt-4o", providerID: .openAI, tier: .cloudAdvanced, displayName: "GPT-4o"
                )
            )
        ]
        self.defaultTierModelMapping = TierModelMapping(
            cloudFast: cloudFastOptions[0].descriptor,
            cloudAdvanced: cloudAdvancedOptions[0].descriptor
        )

        self.providerRegistry = ProviderRegistry(
            cloudProviders: cloudProviders,
            localModelManager: localModelManager,
            settingsStore: settingsStore,
            defaultTierModelMapping: defaultTierModelMapping,
            defaultLocalTextModel: LocalModelCatalog.defaultText,
            defaultLocalVisionModel: LocalModelCatalog.defaultVision
        )

        let usageLimiter = DefaultUsageLimiter(usageStore: usageStore, settingsStore: settingsStore)
        self.usageLimiter = usageLimiter
        self.networkStatusMonitor = NetworkStatusMonitor()

        self.routingCoordinator = RoutingCoordinator(
            router: PromptedLocalQueryRouter(
                modelManager: localModelManager,
                modelID: LocalModelCatalog.defaultText.id
            ),
            logStore: routingLogStore,
            usageLimiter: usageLimiter,
            networkStatus: NWPathMonitorNetworkStatus(),
            settingsStore: settingsStore
        )
    }

    /// Maps a persisted `Message.modelID` back to a friendly badge label. Checks
    /// both local catalogs (not just "the" local model) since the active local
    /// model can change over time — older messages keep whichever model id they
    /// were actually sent with.
    func displayName(forModelID modelID: String) -> String {
        if let match = LocalModelCatalog.textModels.first(where: { $0.id == modelID }) { return match.displayName }
        if let match = LocalModelCatalog.visionModels.first(where: { $0.id == modelID }) { return match.displayName }
        if let match = (cloudFastOptions + cloudAdvancedOptions).first(where: { $0.descriptor.id == modelID }) {
            return match.descriptor.displayName
        }
        return modelID
    }
}
```

- [ ] **Step 2: Confirm `AIChatRouterKit` references compile from the app target**

Run: `cd "/Users/sayantanprojects/Documents/AI app" && xcodegen generate && xcodebuild -project AIChatRouter.xcodeproj -scheme AIChatRouter -destination 'platform=macOS' build 2>&1 | tail -80`
Expected: The build still fails — `LocalModelSettingsViewModel.swift` and `ChatViewModel.swift`/`ChatView.swift` still reference the old APIs (`LocalModelCatalog.all`/`.default`, `ImageAttachmentStore` not yet wired into `ChatViewModel`'s init). Confirm the *only* remaining errors are in `LocalModelSettingsViewModel.swift` (fixed in Task 10) and, once that's fixed, in `ChatViewModel.swift`'s constructor call in `ChatView.swift` (fixed in Tasks 12–13). `AppEnvironment.swift` itself must show no errors.

- [ ] **Step 3: Commit**

```bash
git add AIChatRouter/Support/AppEnvironment.swift
git commit -m "refactor: AppEnvironment builds local providers on demand via ProviderRegistry"
```

---

## Task 10: `LocalModelSettingsViewModel`/`View` — text and vision sections

No automated test (app target has no test suite). Deliverable: a successful build plus a manual check that both sections appear, each downloads independently, and each selection persists.

**Files:**
- Modify: `AIChatRouter/ViewModels/LocalModelSettingsViewModel.swift`
- Modify: `AIChatRouter/Views/Settings/LocalModelSettingsView.swift`
- Modify: `AIChatRouter/Views/Settings/SettingsView.swift:12`

**Interfaces:**
- Consumes: `LocalModelOption.ModelKind`, `LocalModelCatalog.textModels`/`.visionModels` (Task 2), `LocalModelManager.loadedContainer(for:kind:)` (Task 3), `AppSettingsStore.loadActiveLocalTextModelID`/`saveActiveLocalTextModelID`/`loadActiveLocalVisionModelID`/`saveActiveLocalVisionModelID` (Task 5).
- Produces: `LocalModelSettingsViewModel.init(kind:modelManager:settingsStore:)`; `LocalModelSettingsView.init(modelManager:settingsStore:)`.

- [ ] **Step 1: Implement the view model**

Replace `LocalModelSettingsViewModel.swift`:

```swift
import Foundation
import Observation
import AIChatRouterKit

@Observable
@MainActor
final class LocalModelSettingsViewModel {
    let kind: LocalModelOption.ModelKind
    let options: [LocalModelOption]
    var selectedModelID: String
    private(set) var isDownloading = false
    private(set) var progress: Double?
    private(set) var statusMessage: String = "Not downloaded yet."

    private let modelManager: LocalModelManager
    private let settingsStore: AppSettingsStore

    init(kind: LocalModelOption.ModelKind, modelManager: LocalModelManager, settingsStore: AppSettingsStore) {
        self.kind = kind
        self.modelManager = modelManager
        self.settingsStore = settingsStore
        switch kind {
        case .text:
            self.options = LocalModelCatalog.textModels
            self.selectedModelID = settingsStore.loadActiveLocalTextModelID(default: LocalModelCatalog.defaultText.id)
        case .vision:
            self.options = LocalModelCatalog.visionModels
            self.selectedModelID = settingsStore.loadActiveLocalVisionModelID(default: LocalModelCatalog.defaultVision.id)
        }
    }

    func save() {
        switch kind {
        case .text: settingsStore.saveActiveLocalTextModelID(selectedModelID)
        case .vision: settingsStore.saveActiveLocalVisionModelID(selectedModelID)
        }
    }

    func refreshStatus() async {
        switch await modelManager.state(for: selectedModelID) {
        case .notDownloaded:
            statusMessage = "Not downloaded yet."
        case .downloading(let fraction):
            statusMessage = "Downloading…"
            progress = fraction
        case .ready:
            statusMessage = "Ready — loaded and cached in ~/.cache/huggingface/hub."
        case .failed(let message):
            statusMessage = "Failed: \(message)"
        }
    }

    func downloadAndLoad() async {
        guard !isDownloading else { return }
        isDownloading = true
        progress = 0
        statusMessage = "Downloading…"

        do {
            _ = try await modelManager.loadedContainer(for: selectedModelID, kind: kind) { [weak self] fraction in
                Task { @MainActor in
                    self?.progress = fraction
                }
            }
            statusMessage = "Ready — loaded and cached in ~/.cache/huggingface/hub."
            progress = 1
        } catch {
            statusMessage = "Failed: \(error.localizedDescription)"
        }

        isDownloading = false
    }
}
```

- [ ] **Step 2: Implement the view**

Replace `LocalModelSettingsView.swift`:

```swift
import SwiftUI
import AIChatRouterKit

struct LocalModelSettingsView: View {
    @State private var textViewModel: LocalModelSettingsViewModel
    @State private var visionViewModel: LocalModelSettingsViewModel

    init(modelManager: LocalModelManager, settingsStore: AppSettingsStore) {
        _textViewModel = State(initialValue: LocalModelSettingsViewModel(
            kind: .text, modelManager: modelManager, settingsStore: settingsStore
        ))
        _visionViewModel = State(initialValue: LocalModelSettingsViewModel(
            kind: .vision, modelManager: modelManager, settingsStore: settingsStore
        ))
    }

    var body: some View {
        Form {
            section(for: textViewModel, title: "Text Model")
            section(for: visionViewModel, title: "Vision Model")
        }
        .padding()
        .task {
            await textViewModel.refreshStatus()
            await visionViewModel.refreshStatus()
        }
    }

    private func section(for viewModel: LocalModelSettingsViewModel, title: String) -> some View {
        Section(title) {
            Picker("Model", selection: Binding(
                get: { viewModel.selectedModelID },
                set: { newValue in
                    viewModel.selectedModelID = newValue
                    viewModel.save()
                    Task { await viewModel.refreshStatus() }
                }
            )) {
                ForEach(viewModel.options) { option in
                    Text(option.displayName).tag(option.id)
                }
            }

            Text(viewModel.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)

            if let progress = viewModel.progress, viewModel.isDownloading {
                ProgressView(value: progress)
            }

            Button(viewModel.isDownloading ? "Downloading…" : "Download / Load Model") {
                Task { await viewModel.downloadAndLoad() }
            }
            .disabled(viewModel.isDownloading)
        }
    }
}
```

- [ ] **Step 3: Update the call site in `SettingsView.swift`**

At `SettingsView.swift:12`, change:

```swift
LocalModelSettingsView(modelManager: environment.localModelManager)
```

to:

```swift
LocalModelSettingsView(modelManager: environment.localModelManager, settingsStore: environment.settingsStore)
```

- [ ] **Step 4: Build and confirm no compile errors in these three files**

Run: `cd "/Users/sayantanprojects/Documents/AI app" && xcodegen generate && xcodebuild -project AIChatRouter.xcodeproj -scheme AIChatRouter -destination 'platform=macOS' build 2>&1 | tail -80`
Expected: No errors referencing `LocalModelSettingsViewModel.swift`, `LocalModelSettingsView.swift`, or `SettingsView.swift`. Remaining errors (if any) should now be confined to `ChatViewModel.swift`/`ChatView.swift`, fixed in Tasks 12–13.

- [ ] **Step 5: Manual verification**

Run the app (`open AIChatRouter.xcodeproj` → Run), open Settings → Local Model:
- Both "Text Model" and "Vision Model" sections appear with their own picker, status, progress bar, and download button.
- Switching the Text Model picker's selection persists (quit and relaunch the app, reopen Settings, confirm the same selection is still shown).
- Same check for the Vision Model picker.

- [ ] **Step 6: Commit**

```bash
git add AIChatRouter/ViewModels/LocalModelSettingsViewModel.swift AIChatRouter/Views/Settings/LocalModelSettingsView.swift AIChatRouter/Views/Settings/SettingsView.swift
git commit -m "feat: split local model Settings into text and vision sections"
```

---

## Task 11: `LimitsSettingsView`/`ViewModel` — image attachment size cap field

No automated test (app target has no test suite).

**Files:**
- Modify: `AIChatRouter/ViewModels/LimitsSettingsViewModel.swift`
- Modify: `AIChatRouter/Views/Settings/LimitsSettingsView.swift`

**Interfaces:**
- Consumes: `AppSettingsStore.loadImageAttachmentSizeCapBytes()`/`saveImageAttachmentSizeCapBytes(_:)`, `AppSettingsStore.defaultImageAttachmentSizeCapBytes` (Task 5).

- [ ] **Step 1: Implement the view model change**

In `LimitsSettingsViewModel.swift`, add a new published field, initialize it, and save it:

```swift
    var attachmentSizeCapCharacters: String = ""
    var imageAttachmentSizeCapBytes: String = ""
```

```swift
        attachmentSizeCapCharacters = String(settingsStore.loadAttachmentSizeCapCharacters())
        imageAttachmentSizeCapBytes = String(settingsStore.loadImageAttachmentSizeCapBytes())
```

```swift
        if let value = Int(attachmentSizeCapCharacters) {
            settingsStore.saveAttachmentSizeCapCharacters(value)
        }
        if let value = Int(imageAttachmentSizeCapBytes) {
            settingsStore.saveImageAttachmentSizeCapBytes(value)
        }
```

- [ ] **Step 2: Implement the view change**

In `LimitsSettingsView.swift`, add a new section after the existing "Attachments" section:

```swift
            Section("Image Attachments") {
                TextField("Max source image size (bytes)", text: $viewModel.imageAttachmentSizeCapBytes)
                    .onSubmit { viewModel.save() }
                Text("Leave blank or 0 to use the default (\(AppSettingsStore.defaultImageAttachmentSizeCapBytes) bytes ≈ \(AppSettingsStore.defaultImageAttachmentSizeCapBytes / 1_000_000)MB). Checked before downscaling, so an oversized source photo is rejected outright rather than silently downsized.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
```

- [ ] **Step 3: Build and confirm no compile errors in these two files**

Run: `cd "/Users/sayantanprojects/Documents/AI app" && xcodegen generate && xcodebuild -project AIChatRouter.xcodeproj -scheme AIChatRouter -destination 'platform=macOS' build 2>&1 | tail -80`
Expected: No errors referencing `LimitsSettingsViewModel.swift` or `LimitsSettingsView.swift`.

- [ ] **Step 4: Manual verification**

Run the app, open Settings → Limits, confirm the new "Image Attachments" field appears, accepts a value, and persists it across a relaunch.

- [ ] **Step 5: Commit**

```bash
git add AIChatRouter/ViewModels/LimitsSettingsViewModel.swift AIChatRouter/Views/Settings/LimitsSettingsView.swift
git commit -m "feat: expose the image attachment size cap in Settings → Limits"
```

---

## Task 12: `ChatViewModel` — pending-image state and the routing bypass

No automated test (app target has no test suite) — this task's correctness is verified by build success plus the manual checklist at the end, and is backed by the already-tested `ProviderRegistry`/`ImageDownscaler`/`ImageAttachmentStore` units from Tasks 6–8.

**Files:**
- Modify: `AIChatRouter/ViewModels/ChatViewModel.swift`

**Interfaces:**
- Consumes: `ImageAttachmentStore` (Task 7), `ImageDownscaler` (Task 6), `ProviderRegistry.resolveVision()`/`isLocalModelReady(kind:)` (Task 8), `AppSettingsStore.loadImageAttachmentSizeCapBytes()` (Task 5), `ChatTurn.images` (Task 1).
- Produces: `ChatViewModel.init(..., imageAttachmentStore: ImageAttachmentStore)` (new required param); `pendingImage: Data?`, `pendingImageFilename: String?`, `imageAttachmentsByMessageID: [UUID: ImageAttachment]` (all `private(set)`); `loadImageAttachments() async`; `attachPendingImage(fileURL: URL, extraImagesIgnored: Int = 0) async`; `removePendingImage()`.

- [ ] **Step 1: Add the new dependency and state**

In `ChatViewModel.swift`, add the import and new stored properties/dependency:

```swift
import Foundation
import Observation
import UniformTypeIdentifiers
import AIChatRouterKit
```

```swift
    private(set) var pendingImage: Data?
    private(set) var pendingImageFilename: String?
    private(set) var imageAttachmentsByMessageID: [UUID: ImageAttachment] = [:]
```

```swift
    private let imageAttachmentStore: ImageAttachmentStore
```

Update the initializer to accept and store it:

```swift
    init(
        conversation: Conversation,
        conversationStore: ConversationStore,
        messageStore: MessageStore,
        routingCoordinator: RoutingCoordinator,
        providerRegistry: ProviderRegistry,
        usageLimiter: UsageLimiter,
        settingsStore: AppSettingsStore,
        attachmentStore: AttachmentStore,
        imageAttachmentStore: ImageAttachmentStore
    ) {
        self.conversation = conversation
        self.conversationStore = conversationStore
        self.messageStore = messageStore
        self.routingCoordinator = routingCoordinator
        self.providerRegistry = providerRegistry
        self.usageLimiter = usageLimiter
        self.settingsStore = settingsStore
        self.attachmentStore = attachmentStore
        self.imageAttachmentStore = imageAttachmentStore
    }
```

- [ ] **Step 2: Add `loadImageAttachments`, `attachPendingImage`, `removePendingImage`, and an image-file classifier**

```swift
    func loadImageAttachments() async {
        do {
            let images = try await imageAttachmentStore.images(for: conversation.id)
            imageAttachmentsByMessageID = Dictionary(uniqueKeysWithValues: images.map { ($0.messageID, $0) })
        } catch {
            attachmentError = "Failed to load images: \(error.localizedDescription)"
        }
    }

    /// `extraImagesIgnored` lets the caller (the composer's multi-select/drop
    /// handler) report that more than one image file was picked in a single
    /// action — only the first is ever kept as pending, but the rest must be
    /// surfaced, never silently dropped.
    func attachPendingImage(fileURL: URL, extraImagesIgnored: Int = 0) async {
        guard !isStreaming else {
            attachmentError = "Wait for the current response to finish before attaching an image."
            return
        }
        attachmentError = nil

        guard let data = try? Data(contentsOf: fileURL) else {
            attachmentError = "\(fileURL.lastPathComponent): couldn't read this file."
            return
        }

        let sizeCap = settingsStore.loadImageAttachmentSizeCapBytes()
        guard data.count <= sizeCap else {
            attachmentError = "\(fileURL.lastPathComponent) is \(data.count) bytes, over the \(sizeCap)-byte limit for image attachments."
            return
        }

        guard let downscaled = ImageDownscaler().downscale(data) else {
            attachmentError = "\(fileURL.lastPathComponent): couldn't read this as an image."
            return
        }

        pendingImage = downscaled
        pendingImageFilename = fileURL.lastPathComponent

        if extraImagesIgnored > 0 {
            attachmentError = "Only one image can be attached per message — using \(fileURL.lastPathComponent); ignored \(extraImagesIgnored) other image file(s) from the same selection."
        }
    }

    func removePendingImage() {
        pendingImage = nil
        pendingImageFilename = nil
    }

    static func isImageFile(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image)
    }
```

- [ ] **Step 3: Add the routing bypass to `sendMessage()`**

At the top of `sendMessage()`, capture and clear the pending image alongside the existing `draftText` clear (so a failed send requires re-attaching, exactly like a failed send doesn't restore cleared `draftText`):

```swift
    func sendMessage() async {
        let text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }
        draftText = ""
        errorMessage = nil
        routingNote = nil
        usageWarning = nil
        pendingSearchPermission = false
        pendingSend = nil

        let imageForThisSend = pendingImage
        let imageFilenameForThisSend = pendingImageFilename ?? "image"
        pendingImage = nil
        pendingImageFilename = nil

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

        if let imageData = imageForThisSend {
            await sendWithVisionSlot(
                userMessage: userMessage,
                imageData: imageData,
                imageFilename: imageFilenameForThisSend
            )
            return
        }

        let recentTurns = ContextWindowBuilder().build(from: Array(messages.dropLast()))
        // ... rest of the existing router-driven body is unchanged from here ...
```

Everything from `let recentTurns = ContextWindowBuilder()...` through the end of the existing `sendMessage()` body stays exactly as it is today — only the new `if let imageData = imageForThisSend { ...; return }` block is inserted before it.

Add the new private helper that the bypass calls:

```swift
    /// Deliberately bypasses `RoutingCoordinator`: an attached image always goes to
    /// the local vision slot regardless of tier, usage caps, the search toggle, or
    /// offline state — local inference is free and on-device, so none of that
    /// machinery applies. No routing-log entry is written for this turn either.
    private func sendWithVisionSlot(userMessage: Message, imageData: Data, imageFilename: String) async {
        guard await providerRegistry.isLocalModelReady(kind: .vision) else {
            errorMessage = "The vision model isn't downloaded yet. Download it in Settings → Local Model before attaching images."
            isStreaming = false
            streamingText = ""
            return
        }

        var turns = messages.map {
            ChatTurn(role: ChatTurn.Role(rawValue: $0.role.rawValue) ?? .user, content: $0.content)
        }
        if let lastIndex = turns.indices.last {
            let last = turns[lastIndex]
            turns[lastIndex] = ChatTurn(role: last.role, content: last.content, images: [imageData])
        }

        let (provider, descriptor) = providerRegistry.resolveVision()
        await performSend(
            provider: provider,
            modelDescriptor: descriptor,
            turns: turns,
            enableWebSearch: false
        )

        guard errorMessage == nil, let lastMessage = messages.last, lastMessage.role == .assistant else {
            return
        }

        let imageAttachment = ImageAttachment(
            conversationID: conversation.id,
            messageID: userMessage.id,
            filename: imageFilename,
            imageData: imageData,
            sizeBytes: imageData.count
        )
        do {
            try await imageAttachmentStore.append(imageAttachment)
            imageAttachmentsByMessageID[userMessage.id] = imageAttachment
        } catch {
            attachmentError = "Sent, but failed to save the image for history: \(error.localizedDescription)"
        }
    }
```

- [ ] **Step 4: Update `ChatView.swift`'s `ChatViewModel(...)` construction and `.task` block**

These are also touched in Task 13, but the constructor call must compile before that task's other UI changes — add the new argument now:

At `ChatView.swift`'s `init`, change:

```swift
        _viewModel = State(initialValue: ChatViewModel(
            conversation: conversation,
            conversationStore: environment.conversationStore,
            messageStore: environment.messageStore,
            routingCoordinator: environment.routingCoordinator,
            providerRegistry: environment.providerRegistry,
            usageLimiter: environment.usageLimiter,
            settingsStore: environment.settingsStore,
            attachmentStore: environment.attachmentStore,
            imageAttachmentStore: environment.imageAttachmentStore
        ))
```

And in the `.task` modifier, add the new load call:

```swift
        .task {
            await viewModel.loadMessages()
            await viewModel.loadAttachments()
            await viewModel.loadImageAttachments()
        }
```

- [ ] **Step 5: Build and confirm no compile errors in `ChatViewModel.swift`/`ChatView.swift`'s constructor/`.task`**

Run: `cd "/Users/sayantanprojects/Documents/AI app" && xcodegen generate && xcodebuild -project AIChatRouter.xcodeproj -scheme AIChatRouter -destination 'platform=macOS' build 2>&1 | tail -80`
Expected: No errors referencing `ChatViewModel.swift`. Remaining errors (if any) are in `ChatView.swift`'s composer/UI code, fixed fully in Task 13.

- [ ] **Step 6: Commit**

```bash
git add AIChatRouter/ViewModels/ChatViewModel.swift AIChatRouter/Views/Chat/ChatView.swift
git commit -m "feat: ChatViewModel routes image-bearing messages to the local vision slot, bypassing RoutingCoordinator"
```

---

## Task 13: `ChatView`/`MessageBubbleView` — composer image fork, pending preview, thumbnail rendering

No automated test (app target has no test suite). Deliverable: successful build plus the manual verification checklist below, which directly covers the Review Focus items about regression-checking existing document attachment and the no-vision-model error path.

**Files:**
- Modify: `AIChatRouter/Views/Chat/ChatView.swift`
- Modify: `AIChatRouter/Views/Chat/MessageBubbleView.swift`

**Interfaces:**
- Consumes: `ChatViewModel.pendingImage`/`.pendingImageFilename`/`.imageAttachmentsByMessageID`/`.attachPendingImage(fileURL:extraImagesIgnored:)`/`.removePendingImage()`/`ChatViewModel.isImageFile(_:)` (Task 12).

- [ ] **Step 1: Extend the file importer's allowed types and add the classify-and-dispatch helper**

In `ChatView.swift`, extend `attachmentContentTypes` to include images:

```swift
    private var attachmentContentTypes: [UTType] {
        var types: [UTType] = [.plainText, .pdf, .sourceCode, .text, .image]
        if let docx = UTType(filenameExtension: "docx") { types.append(docx) }
        return types
    }
```

Add a private helper that both the file importer and the drop handler call, so the "first image wins, rest are reported" rule lives in exactly one place:

```swift
    private func handlePickedFiles(_ urls: [URL]) {
        let imageURLs = urls.filter { ChatViewModel.isImageFile($0) }
        let documentURLs = urls.filter { !ChatViewModel.isImageFile($0) }

        Task {
            if let firstImage = imageURLs.first {
                let didAccess = firstImage.startAccessingSecurityScopedResource()
                await viewModel.attachPendingImage(fileURL: firstImage, extraImagesIgnored: imageURLs.count - 1)
                if didAccess { firstImage.stopAccessingSecurityScopedResource() }
            }

            // Sequential, same reasoning as before: addAttachment checks the
            // combined size cap against `attachments` synchronously at the start
            // of each call, so concurrent attaches could both pass the check
            // before either is appended, bypassing the cap multi-select is
            // meant to be checked against.
            for url in documentURLs {
                let didAccess = url.startAccessingSecurityScopedResource()
                await viewModel.addAttachment(fileURL: url)
                if didAccess { url.stopAccessingSecurityScopedResource() }
            }
        }
    }
```

- [ ] **Step 2: Replace the `.fileImporter` and `.onDrop` bodies to use the new helper**

Replace:

```swift
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: attachmentContentTypes,
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result else { return }
            // Attach sequentially, not as separate concurrent Tasks: addAttachment
            // checks the combined size cap against `attachments` synchronously at
            // the start of its own call, so two files attached concurrently could
            // both pass the check before either is appended, bypassing the cap
            // multi-select is explicitly meant to be checked against.
            Task {
                for url in urls {
                    let didAccess = url.startAccessingSecurityScopedResource()
                    await viewModel.addAttachment(fileURL: url)
                    if didAccess { url.stopAccessingSecurityScopedResource() }
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            // Same sequential-attach reasoning as the file importer above: resolve
            // every dropped provider's URL first (fine to do concurrently, it's
            // just reading the URL), then attach them one at a time so the size
            // cap sees each prior file in the same drop before checking the next.
            Task {
                var urls: [URL] = []
                for provider in providers {
                    if let url = await resolveFileURL(from: provider) {
                        urls.append(url)
                    }
                }
                for url in urls {
                    await viewModel.addAttachment(fileURL: url)
                }
            }
            return true
        }
```

with:

```swift
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: attachmentContentTypes,
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result else { return }
            handlePickedFiles(urls)
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            Task {
                var urls: [URL] = []
                for provider in providers {
                    if let url = await resolveFileURL(from: provider) {
                        urls.append(url)
                    }
                }
                handlePickedFiles(urls)
            }
            return true
        }
```

- [ ] **Step 3: Add the pending-image preview strip and pass the per-message image into `MessageBubbleView`**

Add `import AppKit` at the top of `ChatView.swift` (needed for `NSImage`).

In `body`, add the preview strip right after the existing `attachmentChips` block:

```swift
            if !viewModel.attachments.isEmpty {
                attachmentChips
            }

            if let pendingImage = viewModel.pendingImage {
                pendingImagePreview(pendingImage)
            }
```

Add the new view builder near `attachmentChips`:

```swift
    private func pendingImagePreview(_ data: Data) -> some View {
        HStack(spacing: 8) {
            if let nsImage = NSImage(data: data) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            Text("Image attached")
                .font(.caption)
            Spacer()
            Button {
                viewModel.removePendingImage()
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal)
        .padding(.top, 6)
    }
```

Update the `ForEach` that renders messages to pass the matching image attachment:

```swift
                            ForEach(viewModel.messages) { message in
                                MessageBubbleView(
                                    message: message,
                                    imageAttachment: viewModel.imageAttachmentsByMessageID[message.id],
                                    displayName: displayName
                                )
                                .id(message.id)
                            }
```

- [ ] **Step 4: Render the thumbnail in `MessageBubbleView`**

In `MessageBubbleView.swift`, add the new property and render the thumbnail above the message content:

```swift
struct MessageBubbleView: View {
    let message: Message
    let imageAttachment: ImageAttachment?
    let displayName: (String) -> String
    @State private var sourcesExpanded = false

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }
            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                if let imageAttachment, let nsImage = NSImage(data: imageAttachment.imageData) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 240, maxHeight: 240)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                // Only the model's replies get Markdown rendering — a user's own
                // typed message stays literal, since they didn't necessarily
                // intend "#" or "-" at the start of a line as formatting.
                Group {
                    if message.role == .assistant {
                        Markdown(message.content)
                    } else {
                        Text(message.content)
                    }
                }
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
```

Add `import AppKit` at the top of `MessageBubbleView.swift` (needed for `NSImage`).

- [ ] **Step 5: Build**

Run: `cd "/Users/sayantanprojects/Documents/AI app" && xcodegen generate && xcodebuild -project AIChatRouter.xcodeproj -scheme AIChatRouter -destination 'platform=macOS' build 2>&1 | tail -80`
Expected: Build succeeds with zero errors.

- [ ] **Step 6: Manual verification checklist**

Run the app (`open AIChatRouter.xcodeproj` → Run) and check every item — these are the Review Focus items this plan has no automated coverage for:

- [ ] With the vision model **not yet downloaded**: attach an image and confirm the pending thumbnail preview appears normally above the composer (attaching/previewing never depends on the model being downloaded). Then send. Expect a specific error mentioning Settings → Local Model — no hang, no silent multi-GB download attempt.
- [ ] Download the vision model in Settings → Local Model → Vision Model. Attach an image, ask a question about it, send. Expect a real answer referencing the image content, and the user's message bubble shows the image thumbnail.
- [ ] Reopen the conversation (or relaunch the app) — the image thumbnail on that past message still renders from persistence.
- [ ] Attach an image, then click the × to remove it before sending, then send a plain text message. Confirm nothing image-related appears on that message (i.e. no leftover attached image).
- [ ] Attach a `.txt` or `.pdf` file via the paperclip (not an image) — confirm the existing persistent-chip attachment flow still works exactly as before.
- [ ] Drag-and-drop a `.txt` file onto the chat window — confirm it still attaches via the existing chip flow, unaffected by the new image fork.
- [ ] Select two image files at once in the file picker — confirm only the first becomes the pending preview, and a specific "ignored N other image file(s)" message appears (not a silent drop).
- [ ] Switch the active Text Model in Settings, send a plain-text local-tier message, and confirm (via the response and/or the message's model badge) that the newly selected model actually ran — no restart needed.

- [ ] **Step 7: Commit**

```bash
git add AIChatRouter/Views/Chat/ChatView.swift AIChatRouter/Views/Chat/MessageBubbleView.swift
git commit -m "feat: composer image attach flow, pending preview, and message-bubble thumbnails"
```

---

## Task 14: Final integration verification

**Files:** none (verification only).

- [ ] **Step 1: Run the full kit test suite one more time**

Run: `cd AIChatRouterKit && swift build && swift test`
Expected: PASS, all suites — including every new one added in Tasks 1–8.

- [ ] **Step 2: Full app build**

Run: `cd "/Users/sayantanprojects/Documents/AI app" && xcodegen generate && xcodebuild -project AIChatRouter.xcodeproj -scheme AIChatRouter -destination 'platform=macOS' clean build 2>&1 | tail -80`
Expected: Clean build, zero errors, zero new warnings introduced by this feature's files.

- [ ] **Step 3: Re-run the Task 13 manual verification checklist end to end in one sitting**

Confirms nothing regressed across the full set of changes together (as opposed to task-by-task, where each check only covered what existed at that point).

- [ ] **Step 4: Review the diff for anything left over**

Run: `cd "/Users/sayantanprojects/Documents/AI app" && git log --oneline main..HEAD` and `git diff main...HEAD --stat`
Confirm every file touched matches this plan's file lists, and no debug code, `print()` statements, or commented-out old implementations were left behind.

This task produces no commit of its own — it's a verification gate before requesting code review / opening a PR.
