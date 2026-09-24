# File Attachments (v2) — Design

## Context

The original v2 request had two independent sub-projects: web search (built first, now merged into `main`) and RAG/file attachments — "the ability to add files into the chat so the model can read it." This spec covers the second one: letting a user attach plain-text, PDF, or Word documents to a conversation so any model (local or cloud) can answer questions about their content.

This is full-text stuffing, not retrieval-augmented generation with embeddings — the user explicitly chose to build the simpler version first and revisit true RAG (chunking + embedding + vector retrieval, for documents too large to fit in context) as a later, separate sub-project once this ships.

## Decisions

- **Read strategy**: full extracted text is stuffed directly into the model's context via the existing (currently unused) `systemPrompt` parameter on `LLMProvider.streamCompletion` — no embeddings, no vector store, no chunking. This works for both cloud and local models since all three current providers already thread `systemPrompt` through to their underlying API/session.
- **Supported file types**: plain text (`.txt`, `.md`, code files — read as UTF-8) plus `.pdf` and `.docx`, using native macOS frameworks for extraction (PDFKit for PDF, `NSAttributedString`'s built-in Office Open XML reader for docx) — no third-party parsing dependency.
- **Persistence scope**: an attachment is scoped to the whole conversation, not a single message. Once attached, its content is included in every subsequent send until removed. Stored in the database, so it survives app restarts.
- **Routing**: unchanged. An attached file does not bias `RoutingCoordinator`'s tier decision — the router classifies each query's complexity exactly as it does today, independent of whether files are attached. (This is a deliberate difference from the web-search feature, which does force a tier bump — the user chose not to apply the same bias here.)
- **Size limit**: a combined cap of 50,000 characters (roughly 10–15K tokens) across all attachments in a conversation. Attaching a file that would push the total over the cap is rejected outright with a clear error naming the limit — never silently truncated, since a truncated document could give the model a misleading partial picture.
- **Extraction failures** (corrupt/scanned-image PDF with no text layer, unreadable docx, non-UTF8 text): rejected with a specific error, never attached with empty/partial content.
- **Multiple files**: a conversation can have several attachments at once; all of them (within the combined size cap) are included in context together.
- **UI**: a paperclip button in the message composer opens a file picker; the chat window also accepts drag-and-drop. Attached files show as a strip of removable chips above the composer — not tied to any individual message bubble, matching the conversation-level persistence above.
- **Removal**: each chip has a way to detach that file from the conversation (deletes its stored record); future messages stop seeing it, past messages/replies are unaffected.

## Architecture

### Kit-level changes (`AIChatRouterKit`)

- **`Attachment` model** (new, mirrors `Message`'s shape): `id: UUID, conversationID: UUID, filename: String, fileType: String, extractedText: String, sizeBytes: Int, createdAt: Date`. `FetchableRecord`/`PersistableRecord`, table name `attachment`.
- **Persistence migration** (`AppDatabase`, new migration `v3`, additive):
  ```sql
  CREATE TABLE attachment (
    id TEXT PRIMARY KEY,
    conversationID TEXT NOT NULL REFERENCES conversation(id) ON DELETE CASCADE,
    filename TEXT NOT NULL,
    fileType TEXT NOT NULL,
    extractedText TEXT NOT NULL,
    sizeBytes INTEGER NOT NULL,
    createdAt DATETIME NOT NULL
  );
  CREATE INDEX idx_attachment_conversation ON attachment(conversationID);
  ```
- **`AttachmentStore`** (new, mirrors `MessageStore`): `append(_:) async throws`, `attachments(for conversationID:) async throws -> [Attachment]`, `delete(id:) async throws`.
- **`FileTextExtractor`** (new): `func extractText(from url: URL) async throws -> String`. Dispatches on file extension — only `.pdf` and `.docx` get special-cased; every other extension is treated as plain text, so `.txt`, `.md`, and any code/config extension (`.swift`, `.py`, `.json`, `.csv`, ...) all take the same path without needing an enumerated whitelist:
  - `.pdf` → `PDFKit.PDFDocument(url:)`, concatenate `page.string` across all pages; throw if the document fails to load or every page yields empty/nil text (the scanned-image-PDF case).
  - `.docx` → `NSAttributedString(url:options: [.documentType: .officeOpenXML], documentAttributes: nil)`, then `.string`; throw if it fails to parse.
  - Everything else → read as UTF-8 (`String(contentsOf:encoding:)`); throw a specific error if the bytes don't decode as UTF-8 (this is also what naturally rejects a genuinely unsupported binary file, e.g. an image renamed with a text-like extension).
- **New error type**: `AttachmentError: Error { case unreadableAsText, extractionFailed(String), tooLarge(limitCharacters: Int, wouldBeCharacters: Int) }`.

### App-level changes (`AIChatRouter`)

- **`ChatViewModel`**:
  - New published state: `attachments: [Attachment]`, `attachmentError: String?`.
  - `loadAttachments()` (called alongside `loadMessages()` on conversation open).
  - `addAttachment(fileURL: URL) async` — runs `FileTextExtractor` off the main actor, checks the combined size against the cap (existing attachments' `sizeBytes` + the new file's), and either appends via `AttachmentStore` and refreshes `attachments`, or sets `attachmentError` with a specific message.
  - `removeAttachment(_ id: UUID) async` — deletes via `AttachmentStore`, refreshes `attachments`.
  - `sendMessage()` (and the search-permission `allowSearchOverride()`/`denySearchOverride()` paths): before calling `performSend`, build a system prompt from the current `attachments` (e.g. `"The user has attached the following file(s) — use their content to answer questions about them:\n\n--- <filename> ---\n<extractedText>\n\n--- <filename> ---\n..."`, or `nil` if there are none) and pass it as `performSend`'s existing `systemPrompt` argument (currently hardcoded to `nil` in every call site — this becomes the one place that builds it).
- **`ChatView`**:
  - Paperclip `ToolbarItem` or composer-adjacent button opening `NSOpenPanel` (or `.fileImporter` SwiftUI modifier) filtered to the supported extensions; calls `viewModel.addAttachment(fileURL:)`.
  - `.onDrop(of: [.fileURL], ...)` on the chat `VStack`, extracting dropped file URLs and calling the same `addAttachment`.
  - A horizontal `ScrollView` of attachment chips (filename + a type icon + a remove button) above the composer, driven by `viewModel.attachments`.
  - `attachmentError` surfaced the same way `errorMessage` already is (a small red caption near the composer).

## Error Handling

Every failure path (unsupported type, extraction failure, size cap exceeded) produces a specific, user-visible message via `attachmentError` — never a silently-skipped attach or a partially-included document. This mirrors the project's existing principle (established fixing the v1 SSE blank-line bug and the v2 web-search review) that a failure must never look like success.

## Testing

- Unit tests (kit, real files, no mocks): `FileTextExtractorTests` — a plain-text fixture, a small real PDF fixture, a small real docx fixture, all checked into the test target; plus failure cases (unsupported extension, non-UTF8 bytes, a PDF/docx that fails to parse — using a deliberately corrupted/truncated fixture file).
- Unit tests (kit): `AttachmentStore` round-trip (append/fetch/delete) against a real in-memory GRDB database, same pattern as `PersistenceTests`.
- No automated test for the composer/drag-drop UI or the `ChatViewModel` wiring — this app target has no test suite (an established, pre-existing gap, not new to this feature); verified live, same as the web-search feature's UI pieces.

## Non-Goals (this spec)

- True RAG (chunking, embeddings, vector retrieval) for documents too large to fit the size cap — explicitly deferred to a later sub-project.
- Routing bias based on attachment presence (the user chose to leave routing untouched — see Decisions).
- Image/screenshot attachments, or any file type beyond plain text/PDF/docx.
- A user-configurable size cap (Settings UI) — the 50,000-character constant can be exposed later if it proves too restrictive.
- Attachment content appearing in the message-history transcript itself (e.g. showing extracted text inline) — attachments are a context-only input, not a displayed message.
