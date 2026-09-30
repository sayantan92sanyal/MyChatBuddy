# Vision/VLM Support — Design

## Context

The app is text-only end to end today: `ChatTurn.content`/`Message.content` are plain `String`s, `Attachment` only carries extracted text, `LLMProvider.streamCompletion` has no image parameter, and `LocalModelManager` only knows how to load models via MLXLLM's `LLMModelFactory`. The user downloaded and CLI-verified `mlx-community/Qwen3-VL-8B-Thinking-4bit` (~5.4GB) in a dedicated Python 3.12 venv, intending to integrate it as the app's local vision model.

A key finding from exploring the vendored `mlx-swift-lm` package during design: MLXLMCommon's `ChatSession`/`Chat.Message` (already used unmodified by `LocalMLXProvider` today) natively supports images via `images: [UserInput.Image]` (`.ciImage`, `.url`, or `.array` cases), and MLXVLM's `VLMModelFactory` produces the same `ModelContainer` type as MLXLLM's `LLMModelFactory`. This means the local-model runtime layer does not need a parallel VLM-specific stack — it needs the right factory chosen at load time and image data threaded through a call that already accepts it.

## Decisions

- **Provider scope (this pass)**: local VLM only. Anthropic and OpenAI vision are explicitly deferred — Anthropic because it's a separate, self-contained follow-up (native image content blocks, similar effort to the already-shipped web-search wiring); OpenAI because its vision shape can't be live-verified in this environment (same pre-existing blocker as the deferred OpenAI web-search gap).
- **Attachment scope**: per-message, not conversation-wide. An attached image rides along with the one message it's sent with and is never re-sent as context on later turns — unlike text attachments (see `2026-09-24-file-attachments-design.md`), which are intentionally conversation-wide. This matches how vision models are actually used and avoids repeatedly re-encoding image data into every subsequent local turn.
- **Activation model**: a dedicated local vision slot, not a router-aware "needs vision" signal. Today's `.local` tier is a single fixed model (Llama 3.2 3B) used for all local text chat; Qwen3-VL-8B-Thinking is bigger, slower, and has its own "thinking" output style, so it should not replace the default text model. Instead, attaching an image deterministically routes that one turn to a second, independent local model slot, loaded and cached separately. `RoutingCoordinator`/`QueryRouter`/`RoutingDecision` gain no vision concept at all — the decision is already deterministic (image present or not), so teaching the classifier about it would be pure added surface area for no benefit.
- **Routing bypass**: an image-bearing message skips `RoutingCoordinator.decide(...)` entirely — no tier classification, no usage-limiter application, no search-permission logic, no routing-log entry. Local inference is free and on-device regardless of network/usage-cap state, so none of that machinery applies. This is a deliberate omission, not an oversight, and should be called out with a code comment at the bypass point (mirroring how existing deliberate omissions — e.g. the offline-forces-local logic in `RoutingCoordinator` — are already commented).
- **Composer UI**: no new button. The existing paperclip/drag-and-drop flow forks on file type — an image shows as a thumbnail in a small "pending" preview strip above the composer (cleared once that message sends, not persisted as a chip), while non-image files keep today's persistent-chip behavior completely unchanged.
- **Model catalog scope**: curated, hardcoded lists per kind (matching today's text-model pattern), not arbitrary Hugging Face repo entry. Adding a new vetted model later is a one-line addition to the relevant list. Both the text catalog and a new vision catalog become independently selectable and downloadable in Settings.
- **Closing a pre-existing gap**: today `LocalModelSettingsViewModel.selectedModelID` lets a user pick and download a model, but that selection is never wired to what actually runs — `AppEnvironment` hardcodes `LocalModelCatalog.default.id` at launch, and `ProviderRegistry.resolve(tier: .local)` always returns that fixed descriptor. Making Settings selection meaningful for both the text and vision slots requires fixing this: the active model id for each kind is persisted in `AppSettingsStore` and read live on every `resolve(...)` call, exactly like cloud tier mappings already work — so switching the active model in Settings takes effect on the next message, no restart required.

## Architecture

### Kit-level changes (`AIChatRouterKit`)

- **`ChatTurn`**: add `public let images: [Data]` with a default of `[]` in every initializer — every existing call site (router, providers, tests) is unaffected. Only the vision-slot `LocalMLXProvider` instance ever reads this field; every other provider silently ignores it, which is safe because of the routing bypass above (a non-vision provider is never handed a turn with non-empty `images`).
- **`LocalModelOption`** (`LocalModelCatalog`): gains a `kind` field —
  ```swift
  public struct LocalModelOption: Sendable, Identifiable, Hashable {
      public enum ModelKind: Sendable { case text, vision }

      public let id: String
      public let displayName: String
      public let kind: ModelKind
  }
  ```
  `LocalModelCatalog.textModels` keeps today's three entries (Llama 3.2 3B, Qwen2.5 3B, Qwen2.5 7B), each `kind: .text`. New `LocalModelCatalog.visionModels` starts with one entry, `kind: .vision`: `mlx-community/Qwen3-VL-8B-Thinking-4bit`. `LocalModelCatalog.defaultText`/`defaultVision` replace the current single `default`.
- **`LocalModelManager`**: `loadedContainer(for:)` becomes `loadedContainer(for modelID: String, kind: LocalModelOption.ModelKind, progressHandler:)`, dispatching to `LLMModelFactory.shared.loadContainer(...)` for `.text` and `VLMModelFactory.shared.loadContainer(...)` for `.vision`. Both return `MLXLMCommon.ModelContainer`, so the existing per-modelID `containers`/`states` caching dictionaries need no structural change — `kind` only selects which factory populates them. `import MLXVLM` added alongside the existing `import MLXLLM`.
- **`LocalMLXProvider`**: gains a `kind: LocalModelOption.ModelKind` stored property (set at construction, matching whichever model id it wraps). In `streamCompletion`, when `kind == .vision`, `lastUserTurn.images` (`[Data]`) is converted to `[UserInput.Image]` (via a `CIImage`-backed constructor from the raw `Data`) and passed as `session.streamDetails(to: lastUserTurn.content, images: convertedImages)`; when `kind == .text`, behavior is unchanged (`images` is always empty on that path, since the routing bypass guarantees text-slot turns never carry image data).
- **`ProviderID`**: add a `.localVLM` case alongside `.localMLX`, `.anthropic`, `.openAI` — needed because the vision slot is a second, independently-addressable provider instance, not a variant of the existing local-text provider entry.
- **`ImageAttachment` model** (new, separate from `Attachment` — see Persistence below): `id: UUID, conversationID: UUID, messageID: UUID, filename: String, imageData: Data, sizeBytes: Int, createdAt: Date`. `FetchableRecord`/`PersistableRecord`, table name `image_attachment`.
- **Persistence migration** (`AppDatabase`, new additive migration):
  ```sql
  CREATE TABLE image_attachment (
    id TEXT PRIMARY KEY,
    conversationID TEXT NOT NULL REFERENCES conversation(id) ON DELETE CASCADE,
    messageID TEXT NOT NULL REFERENCES message(id) ON DELETE CASCADE,
    filename TEXT NOT NULL,
    imageData BLOB NOT NULL,
    sizeBytes INTEGER NOT NULL,
    createdAt DATETIME NOT NULL
  );
  CREATE INDEX idx_image_attachment_conversation ON image_attachment(conversationID);
  CREATE INDEX idx_image_attachment_message ON image_attachment(messageID);
  ```
- **`ImageAttachmentStore`** (new, mirrors `AttachmentStore`): `append(_:) async throws`, `images(for conversationID:) async throws -> [ImageAttachment]`, `delete(id:) async throws`.
- **Downscaling**: before an image is persisted or sent, its longest edge is capped (e.g. ~1568px) via `CoreGraphics`/`AppKit` resizing — keeps DB blobs small and matches what the vision model needs regardless. A new `AppSettingsStore.loadImageAttachmentSizeCapBytes()` (same Settings → Limits pattern as the existing text-attachment character cap) rejects an source file outright before the downscale runs if it's absurdly large.
- **`AppSettingsStore`**: new persisted keys for the active text-model id, active vision-model id, and the image-attachment size cap — same read/write pattern as the existing `TierModelMapping`/web-search/attachment-cap settings.
- **`ProviderRegistry`**: `resolve(tier: .local)` reads the persisted active text-model id (falling back to `LocalModelCatalog.defaultText`) instead of a fixed descriptor captured at init. A new `resolveVision()` method resolves the vision slot the same way, reading the persisted active vision-model id (falling back to `LocalModelCatalog.defaultVision`).

### App-level changes (`AIChatRouter`)

- **`AppEnvironment`**: constructs a second `LocalMLXProvider` (`kind: .vision`) registered under `providers[.localVLM]`, alongside the existing `.localMLX` text provider. `localDescriptor` is no longer a fixed `let` — both the text and vision descriptors are resolved from `ProviderRegistry` at call time rather than captured once at launch.
- **`LocalModelSettingsViewModel`/`LocalModelSettingsView`**: gains a second, parallel section (or a segmented kind picker) — "Text model" (existing `LocalModelCatalog.textModels`, wired to the newly-added active-text-model setting) and "Vision model" (`LocalModelCatalog.visionModels`, wired to the active-vision-model setting). Both share the same download/progress/status UI, parameterized by `kind`.
- **`ChatViewModel`**:
  - New state: `pendingImage: Data?`, plus a `[UUID: ImageAttachment]` dict (keyed by `messageID`) loaded alongside `loadMessages()` for scrollback rendering.
  - The paperclip/drag-and-drop handler forks on file type: an image sets `pendingImage` (showing the composer preview strip) instead of going through `FileTextExtractor`/`AttachmentStore`.
  - `sendMessage()`: after persisting the user `Message` (as today), checks `pendingImage`. If set: skip `routingCoordinator.decide(...)`, resolve `providers[.localVLM]` + the vision descriptor via `ProviderRegistry.resolveVision()`, attach the image `Data` to the last `ChatTurn`, call `performSend` with that provider, then persist an `ImageAttachment(messageID: userMessage.id, ...)` and clear `pendingImage`. `pendingImage` clears at send time regardless of outcome (matching how `draftText` already clears immediately, before success/failure is known). If not set, the existing router-driven path is unchanged.
  - Existing conversation-wide `attachmentsSystemPrompt` (text attachments) is passed through to the vision provider's `systemPrompt` parameter exactly as it is for every other provider — the two features are orthogonal and both simply feed the same call.
  - `performSend`'s existing "provider not configured" check is extended to the vision slot: if the selected vision model isn't `.ready` in `LocalModelManager`, surface an error directing the user to Settings, rather than triggering a multi-GB download mid-chat.
- **`MessageComposerView`**: adds the pending-image thumbnail preview strip (with a remove control) above the existing text field/paperclip/send row.
- **`MessageBubbleView`**: looks up the message's `ImageAttachment` by `messageID` and renders the thumbnail above the message text when present, both immediately after sending and on conversation reload.

## Error Handling

- **Vision model not downloaded**: `performSend` checks `LocalModelManager.state(for: visionModelID)` (the `states` dictionary stays keyed by modelID alone — text and vision catalogs never share an id, so no signature change is needed there, unlike `loadedContainer`); anything other than `.ready` surfaces a specific `errorMessage` pointing at Settings, mirroring the existing "needs an API key" message for cloud providers.
- **Unreadable/corrupt image**: rejected the same way `FileTextExtractor` rejects an unreadable file today — an inline composer error, `pendingImage` is never set, nothing is sent.
- **Oversized image**: rejected against `loadImageAttachmentSizeCapBytes()` before any downscale work happens, with a specific message naming the limit (never silently truncated or silently downscaled without the user knowing why).
- **Send failure with a pending image**: `pendingImage` is cleared at send time (not on success), so a failed send requires re-attaching — consistent with how a failed send today doesn't restore cleared `draftText` either.
- **Routing/usage-limiter/search-permission**: none of these are invoked for an image-bearing turn — this is a deliberate bypass (see Decisions), marked with a code comment at the point where `sendMessage()` checks `pendingImage` before calling `routingCoordinator.decide(...)`.

## Testing

- `LocalModelManagerTests` (new): verify `loadedContainer(for:kind:)` dispatches to the correct factory-selection branch, using the same injected `Downloader`/`TokenizerLoader` fakes the manager already supports — consistent with existing practice of not exercising real multi-GB downloads in tests.
- `LocalMLXProviderTests` (new or extended): confirm `kind == .vision` threads `turns.last.images` into `streamDetails(images:)`, and `kind == .text` never does.
- `ImageAttachmentStoreTests` (new, mirrors `AttachmentStoreTests`): round-trip persistence against a real in-memory GRDB database, plus size-cap enforcement and downscale-before-store.
- `ProviderRegistryTests` (extend): resolving `.local` and the new vision resolution path read the live persisted model-id setting rather than a fixed value, matching how cloud tier resolution is already tested.
- `ChatViewModel` wiring (composer fork, pending-image send bypass): no automated test — this app target has no test suite today (an established, pre-existing gap, not new to this feature); verified live, same as prior UI-facing pieces of web search and file attachments.

## Non-Goals (this spec)

- Anthropic or OpenAI vision support — explicitly deferred; Anthropic is a self-contained, comparatively small follow-up, OpenAI is blocked on the same missing-API-key verification gap as its deferred web-search support.
- Router/classifier awareness of vision ("needs vision" as a `RoutingDecision` concept) — the dedicated-slot bypass makes this unnecessary.
- Arbitrary Hugging Face repo entry for either model catalog — both stay curated, hardcoded lists.
- Conversation-wide/persistent image context (re-sending a previously attached image on later turns) — images are strictly per-message.
- Video or audio input, despite `UserInput`/`Chat.Message` supporting both — out of scope; this spec covers images only.
- A second local vision model option beyond Qwen3-VL-8B-Thinking-4bit — the curated vision list starts with exactly the one already downloaded and verified.
