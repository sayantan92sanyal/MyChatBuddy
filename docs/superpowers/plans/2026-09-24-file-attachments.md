# File Attachments (v2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a user attach plain-text, PDF, or Word (.docx) files to a conversation so any model (local or cloud) can answer questions about their content.

**Architecture:** Extracted file text is stuffed directly into the existing (currently-unused) `systemPrompt` parameter every `LLMProvider` already accepts — no new provider protocol surface, no embeddings, no vector store. A new `Attachment` model/store persists attachments at the conversation level (not per-message), and `FileTextExtractor` uses only native macOS frameworks (PDFKit, AppKit's `NSAttributedString`) to pull text out of PDFs and docx files.

**Tech Stack:** Swift 6, GRDB (persistence), PDFKit + AppKit (`NSAttributedString`) for extraction, SwiftUI (`.fileImporter`, `.onDrop`) for the attach UI.

**Spec:** `docs/superpowers/specs/2026-09-24-file-attachments-design.md`

## Global Constraints

- Full-text stuffing only — no embeddings, chunking, or vector store (true RAG is a later, separate sub-project).
- Supported types: `.pdf` and `.docx` are special-cased; every other extension is attempted as UTF-8 plain text (covers `.txt`, `.md`, code/config files without an enumerated whitelist).
- Extraction uses only native macOS frameworks (PDFKit, AppKit's `NSAttributedString`) — no third-party dependency.
- Attachments are conversation-scoped (not tied to a specific message), and persist in the database across app restarts.
- Combined size cap: 50,000 characters across all attachments in one conversation. Exceeding it is rejected outright — never truncated.
- No routing bias: `RoutingCoordinator` is untouched. The router classifies every query's complexity exactly as it does today, regardless of whether files are attached.
- Every failure path (unsupported/unreadable file, extraction failure, size cap exceeded) produces a specific, user-visible error — never a silently-skipped attach or a partially-included document.

## Review Focus

- **Combined size-cap arithmetic at the exact boundary** (existing attachments' total length + a new file's length vs. the 50,000-character cap — landing exactly on the limit must not reject): covered directly by Task 1's `wouldExceedLimit` boundary tests, not left as a gap.
- **Removing an attachment must actually stop it being included in the next message sent** — `ChatViewModel` has no automated test target in this project (pre-existing gap, not new to this feature); verified only by Task 5's live checkpoint.
- **A PDF that loads successfully but has no extractable text** (a scanned/image-only page, as opposed to a PDF that fails to load at all — Task 2 covers the load-failure case with a real fixture) must be rejected with a clear error, not attached as an empty document. Verified by code review of `FileTextExtractor`'s explicit empty-text check, and live if a real scanned PDF is available during Task 5.
- **Dragging something onto the chat window that isn't a single readable file** (a folder, an unsupported type, several files where only one is expected) must not crash the app — no automated UI test exists in this project; verified live in Task 5.
- **Attaching a file while a response is currently streaming** must not race with the in-flight send. `addAttachment` is designed to no-op while `isStreaming` is true (Task 3), matching the composer's existing disabled-while-streaming pattern; verified live in Task 5, not by an automated test.

---

## Task 1: Attachment model + persistence

**Files:**
- Create: `AIChatRouterKit/Sources/AIChatRouterKit/Models/Attachment.swift`
- Modify: `AIChatRouterKit/Sources/AIChatRouterKit/Persistence/AppDatabase.swift`
- Create: `AIChatRouterKit/Sources/AIChatRouterKit/Persistence/AttachmentStore.swift`
- Test: `AIChatRouterKit/Tests/AIChatRouterKitTests/AttachmentStoreTests.swift` (new file)

**Interfaces:**
- Produces: `Attachment(id:conversationID:filename:fileType:extractedText:sizeBytes:createdAt:)` (all but `conversationID`/`filename`/`fileType`/`extractedText`/`sizeBytes` defaulted), `AttachmentStore.append(_:) async throws`, `.attachments(for conversationID:) async throws -> [Attachment]`, `.delete(id:) async throws`, `AttachmentStore.combinedCharacterLimit: Int` (static, `50_000`), `AttachmentStore.combinedLength(of: [Attachment]) -> Int` (static, pure), `AttachmentStore.wouldExceedLimit(existing: [Attachment], addingLength: Int) -> Bool` (static, pure — the actual cap-boundary decision, so it's tested here rather than only inside the untested `ChatViewModel`) — all consumed by Task 3.

- [ ] **Step 1: Write the failing tests**

Create `AIChatRouterKit/Tests/AIChatRouterKitTests/AttachmentStoreTests.swift`:

```swift
import Foundation
import Testing
@testable import AIChatRouterKit

@Suite("AttachmentStore")
struct AttachmentStoreTests {
    @Test func appendFetchAndDeleteRoundTrip() async throws {
        let db = try AppDatabase.openInMemory()
        let conversations = ConversationStore(database: db)
        let attachments = AttachmentStore(database: db)

        let conversation = Conversation(title: "Attachment Test")
        try await conversations.create(conversation)

        let attachment = Attachment(
            conversationID: conversation.id,
            filename: "notes.txt",
            fileType: "txt",
            extractedText: "Some extracted text",
            sizeBytes: 20
        )
        try await attachments.append(attachment)

        let fetched = try await attachments.attachments(for: conversation.id)
        #expect(fetched.count == 1)
        #expect(fetched.first?.filename == "notes.txt")
        #expect(fetched.first?.extractedText == "Some extracted text")

        try await attachments.delete(id: attachment.id)
        let afterDelete = try await attachments.attachments(for: conversation.id)
        #expect(afterDelete.isEmpty)
    }

    @Test func deletingConversationCascadesAttachments() async throws {
        let db = try AppDatabase.openInMemory()
        let conversations = ConversationStore(database: db)
        let attachments = AttachmentStore(database: db)

        let conversation = Conversation(title: "To Delete")
        try await conversations.create(conversation)
        try await attachments.append(Attachment(
            conversationID: conversation.id,
            filename: "a.txt",
            fileType: "txt",
            extractedText: "text",
            sizeBytes: 4
        ))

        try await conversations.delete(id: conversation.id)

        let remaining = try await attachments.attachments(for: conversation.id)
        #expect(remaining.isEmpty)
    }

    @Test func combinedLengthSumsExtractedTextAcrossAttachments() {
        let a = Attachment(conversationID: UUID(), filename: "a.txt", fileType: "txt", extractedText: "12345", sizeBytes: 5)
        let b = Attachment(conversationID: UUID(), filename: "b.txt", fileType: "txt", extractedText: "1234567890", sizeBytes: 10)
        #expect(AttachmentStore.combinedLength(of: [a, b]) == 15)
    }

    @Test func combinedLengthOfEmptyArrayIsZero() {
        #expect(AttachmentStore.combinedLength(of: []) == 0)
    }

    @Test func wouldExceedLimitIsFalseExactlyAtTheBoundary() {
        // Existing total + new length landing exactly on the cap must NOT count
        // as exceeding it — this is the off-by-one this helper exists to pin down.
        let existing = [Attachment(
            conversationID: UUID(), filename: "a.txt", fileType: "txt",
            extractedText: String(repeating: "x", count: AttachmentStore.combinedCharacterLimit - 100),
            sizeBytes: 0
        )]
        #expect(AttachmentStore.wouldExceedLimit(existing: existing, addingLength: 100) == false)
    }

    @Test func wouldExceedLimitIsTrueOneOverTheBoundary() {
        let existing = [Attachment(
            conversationID: UUID(), filename: "a.txt", fileType: "txt",
            extractedText: String(repeating: "x", count: AttachmentStore.combinedCharacterLimit - 100),
            sizeBytes: 0
        )]
        #expect(AttachmentStore.wouldExceedLimit(existing: existing, addingLength: 101) == true)
    }

    @Test func wouldExceedLimitIsFalseWellUnderTheCap() {
        #expect(AttachmentStore.wouldExceedLimit(existing: [], addingLength: 500) == false)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd "AIChatRouterKit" && swift test --filter AttachmentStoreTests`
Expected: FAIL — `Attachment` and `AttachmentStore` not found in scope (compile error).

- [ ] **Step 3: Add the migration**

In `AIChatRouterKit/Sources/AIChatRouterKit/Persistence/AppDatabase.swift`, add a third migration after the existing `migrator.registerMigration("v2") { ... }` block, still inside the `migrator` computed property, before `return migrator`:

```swift
        migrator.registerMigration("v3") { db in
            try db.create(table: "attachment") { t in
                t.column("id", .blob).primaryKey()
                t.column("conversationID", .blob).notNull()
                    .references("conversation", onDelete: .cascade)
                t.column("filename", .text).notNull()
                t.column("fileType", .text).notNull()
                t.column("extractedText", .text).notNull()
                t.column("sizeBytes", .integer).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(
                index: "idx_attachment_conversation",
                on: "attachment",
                columns: ["conversationID"]
            )
        }
```

- [ ] **Step 4: Create the Attachment model**

Create `AIChatRouterKit/Sources/AIChatRouterKit/Models/Attachment.swift`:

```swift
import Foundation
import GRDB

public struct Attachment: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var conversationID: UUID
    public var filename: String
    public var fileType: String
    public var extractedText: String
    public var sizeBytes: Int
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        conversationID: UUID,
        filename: String,
        fileType: String,
        extractedText: String,
        sizeBytes: Int,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.conversationID = conversationID
        self.filename = filename
        self.fileType = fileType
        self.extractedText = extractedText
        self.sizeBytes = sizeBytes
        self.createdAt = createdAt
    }
}

extension Attachment: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "attachment"
}
```

- [ ] **Step 5: Create AttachmentStore**

Create `AIChatRouterKit/Sources/AIChatRouterKit/Persistence/AttachmentStore.swift`:

```swift
import Foundation
import GRDB

public struct AttachmentStore: Sendable {
    /// Combined character budget across every attachment in one conversation —
    /// generous enough for real documents while staying comfortably inside any
    /// current cloud model's context window alongside real conversation history.
    public static let combinedCharacterLimit = 50_000

    private let dbQueue: DatabaseQueue

    public init(database: AppDatabase) {
        self.dbQueue = database.dbQueue
    }

    public func append(_ attachment: Attachment) async throws {
        try await dbQueue.write { db in try attachment.insert(db) }
    }

    public func attachments(for conversationID: UUID) async throws -> [Attachment] {
        try await dbQueue.read { db in
            try Attachment
                .filter(Column("conversationID") == conversationID)
                .order(Column("createdAt"))
                .fetchAll(db)
        }
    }

    public func delete(id: UUID) async throws {
        _ = try await dbQueue.write { db in try Attachment.deleteOne(db, key: id) }
    }

    /// Pure helper so the combined-size math (existing attachments' total plus a
    /// candidate new one) can be verified without a database — this two-step
    /// arithmetic, not the storage itself, is the part most likely to have an
    /// off-by-one bug.
    public static func combinedLength(of attachments: [Attachment]) -> Int {
        attachments.reduce(0) { $0 + $1.extractedText.count }
    }

    /// The actual cap-boundary decision, kept here (not inline in `ChatViewModel`,
    /// which has no automated test target in this app) so the off-by-one — landing
    /// exactly on the limit must NOT count as exceeding it — is verified by a test.
    public static func wouldExceedLimit(existing: [Attachment], addingLength: Int) -> Bool {
        combinedLength(of: existing) + addingLength > combinedCharacterLimit
    }
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `cd "AIChatRouterKit" && swift test --filter AttachmentStoreTests`
Expected: PASS (7 tests).

- [ ] **Step 7: Run the full kit test suite and build**

Run: `cd "AIChatRouterKit" && swift build && swift test`
Expected: BUILD SUCCEEDED; 64 tests pass (57 baseline + 7 new).

- [ ] **Step 8: Commit**

```bash
git add AIChatRouterKit/Sources/AIChatRouterKit/Models/Attachment.swift \
        AIChatRouterKit/Sources/AIChatRouterKit/Persistence/AppDatabase.swift \
        AIChatRouterKit/Sources/AIChatRouterKit/Persistence/AttachmentStore.swift \
        AIChatRouterKit/Tests/AIChatRouterKitTests/AttachmentStoreTests.swift
git commit -m "feat: add Attachment model and persistence"
```

---

## Task 2: FileTextExtractor (plain text, PDF, docx)

**Files:**
- Create: `AIChatRouterKit/Sources/AIChatRouterKit/Attachments/FileTextExtractor.swift`
- Modify: `AIChatRouterKit/Package.swift` (add test-target resources)
- Test: `AIChatRouterKit/Tests/AIChatRouterKitTests/FileTextExtractorTests.swift` (new file)
- Test fixtures: `AIChatRouterKit/Tests/AIChatRouterKitTests/Fixtures/fixture.txt`, `fixture.pdf`, `fixture.docx`, `fixture-invalid.pdf`, `fixture-invalid.docx`, `fixture-invalid-utf8.txt` (new files, generated in Step 1 below)

**Interfaces:**
- Produces: `AttachmentError: Error { case unreadableAsText, extractionFailed(String) }`, `FileTextExtractor().extractText(from: URL) async throws -> String` — consumed by Task 3. (The combined-size-cap check is owned by `ChatViewModel`/`AttachmentStore` in Task 3, not `FileTextExtractor` — a single-file extractor has no visibility into a conversation's *other* attachments, so it can't be the thing that throws a "too large combined" error.)

This task's fixture files are real, verified-working PDF/docx files, not hand-authored guesses — generate them exactly as follows before writing any test code, and check them into the repo.

- [ ] **Step 1: Generate the test fixtures**

Run from the repo root:

```bash
mkdir -p AIChatRouterKit/Tests/AIChatRouterKitTests/Fixtures
FIXTURES="AIChatRouterKit/Tests/AIChatRouterKitTests/Fixtures"

# Plain text fixture
echo "Hello docx fixture content for extraction test." > "$FIXTURES/fixture.txt"

# Valid docx, generated from the text fixture via macOS's built-in textutil
textutil -convert docx "$FIXTURES/fixture.txt" -output "$FIXTURES/fixture.docx"

# Valid PDF, generated via CoreGraphics (guarantees a well-formed PDF, unlike
# hand-writing raw PDF bytes)
cat > /tmp/makepdf.swift << 'SCRIPT'
import Foundation
import CoreGraphics

let path = CommandLine.arguments[1]
let url = URL(fileURLWithPath: path)
var mediaBox = CGRect(x: 0, y: 0, width: 200, height: 200)
guard let ctx = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
    fatalError("could not create pdf context")
}
ctx.beginPDFPage(nil)
let attrString = NSAttributedString(
    string: "Hello PDF fixture",
    attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, 18, nil)]
)
let line = CTLineCreateWithAttributedString(attrString)
ctx.textPosition = CGPoint(x: 10, y: 100)
CTLineDraw(line, ctx)
ctx.endPDFPage()
ctx.closePDF()
SCRIPT
swift /tmp/makepdf.swift "$FIXTURES/fixture.pdf"

# Invalid fixtures: a plain-text file wearing a .pdf/.docx extension, to
# exercise the "fails to open" paths — PDFDocument/NSAttributedString both
# reject these cleanly rather than crashing (verified during planning).
cp "$FIXTURES/fixture.txt" "$FIXTURES/fixture-invalid.pdf"
cp "$FIXTURES/fixture.txt" "$FIXTURES/fixture-invalid.docx"

# Invalid UTF-8 bytes, to exercise the plain-text decode failure path.
printf '\xff\xfe\x00\x01invalid utf8 \xc3\x28 bytes' > "$FIXTURES/fixture-invalid-utf8.txt"

ls -la "$FIXTURES"
```

Expected: all six files listed, `fixture.pdf` reported as a real PDF by `file "$FIXTURES/fixture.pdf"` (`PDF document, version 1.3, 1 pages`), `fixture.docx` reported as `Microsoft Word 2007+` by `file "$FIXTURES/fixture.docx"`.

- [ ] **Step 2: Declare the fixtures as test-target resources**

In `AIChatRouterKit/Package.swift`, change:

```swift
        .testTarget(
            name: "AIChatRouterKitTests",
            dependencies: ["AIChatRouterKit"]
        )
```

to:

```swift
        .testTarget(
            name: "AIChatRouterKitTests",
            dependencies: ["AIChatRouterKit"],
            resources: [.copy("Fixtures")]
        )
```

- [ ] **Step 3: Write the failing tests**

Create `AIChatRouterKit/Tests/AIChatRouterKitTests/FileTextExtractorTests.swift`:

```swift
import Foundation
import Testing
@testable import AIChatRouterKit

@Suite("FileTextExtractor")
struct FileTextExtractorTests {
    private func fixture(_ name: String) throws -> URL {
        let fixturesDir = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        return fixturesDir.appendingPathComponent(name)
    }

    @Test func extractsPlainTextFile() async throws {
        let text = try await FileTextExtractor().extractText(from: fixture("fixture.txt"))
        #expect(text.contains("Hello docx fixture content"))
    }

    @Test func extractsPDFText() async throws {
        let text = try await FileTextExtractor().extractText(from: fixture("fixture.pdf"))
        #expect(text.contains("Hello PDF fixture"))
    }

    @Test func extractsDocxText() async throws {
        let text = try await FileTextExtractor().extractText(from: fixture("fixture.docx"))
        #expect(text.contains("Hello docx fixture content"))
    }

    @Test func throwsExtractionFailedForInvalidPDF() async throws {
        await #expect(throws: AttachmentError.self) {
            _ = try await FileTextExtractor().extractText(from: try fixture("fixture-invalid.pdf"))
        }
    }

    @Test func throwsExtractionFailedForInvalidDocx() async throws {
        await #expect(throws: AttachmentError.self) {
            _ = try await FileTextExtractor().extractText(from: try fixture("fixture-invalid.docx"))
        }
    }

    @Test func throwsUnreadableAsTextForNonUTF8Bytes() async throws {
        await #expect(throws: AttachmentError.self) {
            _ = try await FileTextExtractor().extractText(from: try fixture("fixture-invalid-utf8.txt"))
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they fail**

Run: `cd "AIChatRouterKit" && swift test --filter FileTextExtractorTests`
Expected: FAIL — `FileTextExtractor` and `AttachmentError` not found in scope (compile error).

- [ ] **Step 5: Implement FileTextExtractor**

Create `AIChatRouterKit/Sources/AIChatRouterKit/Attachments/FileTextExtractor.swift`:

```swift
import Foundation
import PDFKit
import AppKit

public enum AttachmentError: Error, Sendable, Equatable {
    case unreadableAsText
    case extractionFailed(String)
}

/// Extracts plain text from a file so it can be stuffed into a model's context
/// via `LLMProvider.streamCompletion`'s `systemPrompt` parameter. Only `.pdf` and
/// `.docx` are special-cased; every other extension is attempted as UTF-8 plain
/// text, which covers `.txt`, `.md`, and any code/config file without needing an
/// enumerated whitelist — and naturally rejects a genuinely unsupported binary
/// file (it won't decode as valid UTF-8).
public struct FileTextExtractor: Sendable {
    public init() {}

    public func extractText(from url: URL) async throws -> String {
        switch url.pathExtension.lowercased() {
        case "pdf":
            return try extractFromPDF(url: url)
        case "docx":
            return try extractFromDocx(url: url)
        default:
            return try extractPlainText(url: url)
        }
    }

    private func extractPlainText(url: URL) throws -> String {
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
            throw AttachmentError.unreadableAsText
        }
        return text
    }

    private func extractFromPDF(url: URL) throws -> String {
        guard let document = PDFDocument(url: url) else {
            throw AttachmentError.extractionFailed("Couldn't open this PDF.")
        }
        var text = ""
        for index in 0..<document.pageCount {
            if let page = document.page(at: index), let pageText = page.string {
                text += pageText
            }
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AttachmentError.extractionFailed("This PDF has no extractable text (it may be a scanned image).")
        }
        return text
    }

    private func extractFromDocx(url: URL) throws -> String {
        do {
            let attributed = try NSAttributedString(
                url: url,
                options: [.documentType: NSAttributedString.DocumentType.officeOpenXML],
                documentAttributes: nil
            )
            return attributed.string
        } catch {
            throw AttachmentError.extractionFailed("Couldn't open this Word document.")
        }
    }
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `cd "AIChatRouterKit" && swift test --filter FileTextExtractorTests`
Expected: PASS (6 tests). Note: the invalid-PDF test may print a line like `CoreGraphics PDF has logged an error...` to stderr — this is expected noise from `PDFDocument`'s own diagnostics when given non-PDF content, not a test failure.

- [ ] **Step 7: Run the full kit test suite and build**

Run: `cd "AIChatRouterKit" && swift build && swift test`
Expected: BUILD SUCCEEDED; 70 tests pass (64 + 6 new).

- [ ] **Step 8: Commit**

```bash
git add AIChatRouterKit/Sources/AIChatRouterKit/Attachments/FileTextExtractor.swift \
        AIChatRouterKit/Package.swift \
        AIChatRouterKit/Tests/AIChatRouterKitTests/FileTextExtractorTests.swift \
        AIChatRouterKit/Tests/AIChatRouterKitTests/Fixtures
git commit -m "feat: add FileTextExtractor for plain text, PDF, and docx"
```

---

## Task 3: ChatViewModel + AppEnvironment wiring

**Files:**
- Modify: `AIChatRouter/ViewModels/ChatViewModel.swift`
- Modify: `AIChatRouter/Support/AppEnvironment.swift`
- Modify: `AIChatRouter/Views/Chat/ChatView.swift` (just the `ChatViewModel` init call — UI additions are Task 4)

**Interfaces:**
- Consumes: `Attachment` (Task 1), `AttachmentStore.append/attachments/delete/combinedLength/combinedCharacterLimit` (Task 1), `FileTextExtractor`/`AttachmentError` (Task 2).
- Produces: `ChatViewModel.attachments: [Attachment]`, `.attachmentError: String?`, `.loadAttachments() async`, `.addAttachment(fileURL: URL) async`, `.removeAttachment(_ id: UUID) async` — consumed by `ChatView` in Task 4. `ChatViewModel.init(...)` — **signature change**, adds a required `attachmentStore: AttachmentStore` parameter.

This app target has no automated test suite (SwiftUI `@Observable` view models in this project are verified via the live app checkpoint — see the web-search plan's Task 8 for the established precedent). Proceed carefully and re-read each step against the current file before editing.

- [ ] **Step 1: Add attachmentStore to ChatViewModel's init**

In `AIChatRouter/ViewModels/ChatViewModel.swift`, add a new stored property and init parameter:

```swift
    private let attachmentStore: AttachmentStore
```

right after `private let settingsStore: AppSettingsStore`, and add `attachmentStore: AttachmentStore` as the last parameter of `init(...)`, assigning `self.attachmentStore = attachmentStore` alongside the other assignments.

- [ ] **Step 2: Add attachment state and loadAttachments()**

In the same file, add new published state alongside the existing ones (after `private(set) var pendingSearchPermission = false`):

```swift
    private(set) var attachments: [Attachment] = []
    private(set) var attachmentError: String?
```

Add a new method alongside `loadMessages()`:

```swift
    func loadAttachments() async {
        do {
            attachments = try await attachmentStore.attachments(for: conversation.id)
        } catch {
            attachmentError = "Failed to load attachments: \(error.localizedDescription)"
        }
    }
```

- [ ] **Step 3: Add addAttachment(fileURL:) and removeAttachment(_:)**

Add these two methods after `loadAttachments()`:

```swift
    func addAttachment(fileURL: URL) async {
        guard !isStreaming else { return }
        attachmentError = nil

        let extractedText: String
        do {
            extractedText = try await FileTextExtractor().extractText(from: fileURL)
        } catch AttachmentError.unreadableAsText {
            attachmentError = "\(fileURL.lastPathComponent): couldn't read this as text."
            return
        } catch AttachmentError.extractionFailed(let reason) {
            attachmentError = "\(fileURL.lastPathComponent): \(reason)"
            return
        } catch {
            attachmentError = "\(fileURL.lastPathComponent): \(error.localizedDescription)"
            return
        }

        guard !AttachmentStore.wouldExceedLimit(existing: attachments, addingLength: extractedText.count) else {
            let wouldBeTotal = AttachmentStore.combinedLength(of: attachments) + extractedText.count
            attachmentError = "\(fileURL.lastPathComponent) would push attachments to \(wouldBeTotal) characters, over the \(AttachmentStore.combinedCharacterLimit)-character limit for this conversation."
            return
        }

        let sizeBytes: Int
        if let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           let fileSize = attributes[.size] as? Int {
            sizeBytes = fileSize
        } else {
            sizeBytes = extractedText.utf8.count
        }

        let attachment = Attachment(
            conversationID: conversation.id,
            filename: fileURL.lastPathComponent,
            fileType: fileURL.pathExtension,
            extractedText: extractedText,
            sizeBytes: sizeBytes
        )

        do {
            try await attachmentStore.append(attachment)
            attachments.append(attachment)
        } catch {
            attachmentError = "Failed to save \(fileURL.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func removeAttachment(_ id: UUID) async {
        do {
            try await attachmentStore.delete(id: id)
            attachments.removeAll { $0.id == id }
        } catch {
            attachmentError = "Failed to remove attachment: \(error.localizedDescription)"
        }
    }
```

- [ ] **Step 4: Build the system prompt from attachments and wire it into performSend**

Add a private computed property near the top of the class body (after the `pendingSend` property):

```swift
    private var attachmentsSystemPrompt: String? {
        guard !attachments.isEmpty else { return nil }
        let sections = attachments.map { "--- \($0.filename) ---\n\($0.extractedText)" }
        return "The user has attached the following file(s) — use their content to answer questions about them:\n\n"
            + sections.joined(separator: "\n\n")
    }
```

In `performSend(...)`, change:

```swift
            let stream = provider.streamCompletion(
                model: modelDescriptor,
                systemPrompt: nil,
                turns: turns,
                maxOutputTokens: 1024,
                enableWebSearch: enableWebSearch
            )
```

to:

```swift
            let stream = provider.streamCompletion(
                model: modelDescriptor,
                systemPrompt: attachmentsSystemPrompt,
                turns: turns,
                maxOutputTokens: 1024,
                enableWebSearch: enableWebSearch
            )
```

(This is the only call site — `sendMessage()`, `allowSearchOverride()`, and `denySearchOverrideWithoutConsumingPending()` all funnel through this one `performSend`, so all three send paths pick up attachments automatically.)

- [ ] **Step 5: Wire attachmentStore into AppEnvironment**

In `AIChatRouter/Support/AppEnvironment.swift`, add a stored property alongside the other stores (near `let messageStore: MessageStore`):

```swift
    let attachmentStore: AttachmentStore
```

and initialize it in `init(database:)` alongside the other store initializations (near `self.messageStore = MessageStore(database: database)`):

```swift
        self.attachmentStore = AttachmentStore(database: database)
```

- [ ] **Step 6: Pass attachmentStore into ChatViewModel's construction**

In `AIChatRouter/Views/Chat/ChatView.swift`, in `init(conversation:environment:)`, add `attachmentStore: environment.attachmentStore` as the last argument to the `ChatViewModel(...)` call.

- [ ] **Step 7: Build the app target**

Run: `cd .. && xcodegen generate && xcodebuild -scheme AIChatRouter -project AIChatRouter.xcodeproj -skipPackagePluginValidation build 2>&1 | grep -E "error:|BUILD SUCCEEDED"`
Expected: `BUILD SUCCEEDED`, zero errors.

- [ ] **Step 8: Run the full kit test suite (regression check)**

Run: `cd "AIChatRouterKit" && swift test 2>&1 | tail -5`
Expected: 70 tests pass, unchanged from Task 2 (this task doesn't touch the kit).

- [ ] **Step 9: Commit**

```bash
git add AIChatRouter/ViewModels/ChatViewModel.swift \
        AIChatRouter/Support/AppEnvironment.swift \
        AIChatRouter/Views/Chat/ChatView.swift
git commit -m "feat: wire attachments into ChatViewModel and the send path"
```

---

## Task 4: Attach UI — paperclip, drag-and-drop, chips

**Files:**
- Modify: `AIChatRouter/Views/Chat/MessageComposerView.swift`
- Modify: `AIChatRouter/Views/Chat/ChatView.swift`

**Interfaces:**
- Consumes: `ChatViewModel.attachments/.attachmentError/.loadAttachments()/.addAttachment(fileURL:)/.removeAttachment(_:)` (Task 3).

- [ ] **Step 1: Add a paperclip button to MessageComposerView**

Replace the full contents of `AIChatRouter/Views/Chat/MessageComposerView.swift`:

```swift
import SwiftUI

struct MessageComposerView: View {
    @Binding var text: String
    var isSending: Bool
    var onSend: () -> Void
    var onAttach: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Button(action: onAttach) {
                Image(systemName: "paperclip")
            }
            .buttonStyle(.plain)
            .disabled(isSending)
            .help("Attach a file")

            TextField("Message", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.1)))
                .onKeyPress(.return, phases: .down) { keyPress in
                    guard !keyPress.modifiers.contains(.shift) else { return .ignored }
                    guard !isSending, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        return .ignored
                    }
                    onSend()
                    return .handled
                }

            Button(action: onSend) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(10)
    }
}
```

- [ ] **Step 2: Wire the paperclip, file importer, drag-and-drop, chips, and error display into ChatView**

Replace the full contents of `AIChatRouter/Views/Chat/ChatView.swift`:

```swift
import SwiftUI
import UniformTypeIdentifiers
import AIChatRouterKit

struct ChatView: View {
    @State private var viewModel: ChatViewModel
    @State private var webSearchEnabled: Bool
    @State private var showingFileImporter = false
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
            settingsStore: environment.settingsStore,
            attachmentStore: environment.attachmentStore
        ))
    }

    private var attachmentContentTypes: [UTType] {
        var types: [UTType] = [.plainText, .pdf, .sourceCode, .text]
        if let docx = UTType(filenameExtension: "docx") { types.append(docx) }
        return types
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

            if !viewModel.attachments.isEmpty {
                attachmentChips
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

            if let attachmentError = viewModel.attachmentError {
                Text(attachmentError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }

            Divider()

            MessageComposerView(
                text: $viewModel.draftText,
                isSending: viewModel.isStreaming,
                onSend: { Task { await viewModel.sendMessage() } },
                onAttach: { showingFileImporter = true }
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
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: attachmentContentTypes,
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result else { return }
            for url in urls {
                let didAccess = url.startAccessingSecurityScopedResource()
                Task {
                    await viewModel.addAttachment(fileURL: url)
                    if didAccess { url.stopAccessingSecurityScopedResource() }
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { await viewModel.addAttachment(fileURL: url) }
                }
            }
            return true
        }
        .task {
            await viewModel.loadMessages()
            await viewModel.loadAttachments()
        }
    }

    private var attachmentChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(viewModel.attachments) { attachment in
                    HStack(spacing: 4) {
                        Image(systemName: "doc.text")
                        Text(attachment.filename)
                            .font(.caption)
                            .lineLimit(1)
                        Button {
                            Task { await viewModel.removeAttachment(attachment.id) }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
                }
            }
            .padding(.horizontal)
            .padding(.top, 6)
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

- [ ] **Step 3: Build the app target**

Run: `cd .. && xcodegen generate && xcodebuild -scheme AIChatRouter -project AIChatRouter.xcodeproj -skipPackagePluginValidation build 2>&1 | grep -E "error:|BUILD SUCCEEDED"`
Expected: `BUILD SUCCEEDED`, zero errors.

- [ ] **Step 4: Commit**

```bash
git add AIChatRouter/Views/Chat/MessageComposerView.swift AIChatRouter/Views/Chat/ChatView.swift
git commit -m "feat: add paperclip button, drag-and-drop, and attachment chips"
```

---

## Task 5: Live app checkpoint

**Files:** none (verification only).

- [ ] **Step 1: Relaunch the app**

```bash
pkill -f "AIChatRouter.app/Contents/MacOS/AIChatRouter" 2>/dev/null
sleep 1
cd "/Users/sayantanprojects/Documents/AI app"
xcodegen generate && xcodebuild -scheme AIChatRouter -project AIChatRouter.xcodeproj -skipPackagePluginValidation build 2>&1 | grep -E "error:|BUILD SUCCEEDED"
open -n "/Users/sayantanprojects/Library/Developer/Xcode/DerivedData/AIChatRouter-cbuqnompxwgdqkegmtmieiqqvytw/Build/Products/Debug/AIChatRouter.app"
sleep 2
pgrep -fl "AIChatRouter.app/Contents/MacOS/AIChatRouter" && echo RUNNING || echo CRASHED
```

Expected: `BUILD SUCCEEDED` and `RUNNING`.

- [ ] **Step 2: Attach a plain-text file and ask about it**

Click the paperclip, pick a `.txt` file, confirm a chip appears with its filename. Send a message asking a specific question only that file's content would answer. Expected: the reply correctly reflects the file's content, and the routing badge shows whatever tier the query's own complexity warranted (not forced to cloud) — confirming the "no routing bias" decision.

- [ ] **Step 3: Attach a PDF and a docx**

Attach a real `.pdf` and a real `.docx` (any you have handy, or reuse the ones generated for Task 2's fixtures at `AIChatRouterKit/Tests/AIChatRouterKitTests/Fixtures/fixture.pdf` / `fixture.docx`). Ask about each. Expected: both extract correctly and the model can answer from their content; multiple chips appear together.

- [ ] **Step 4: Drag-and-drop**

Drag a file directly onto the chat window instead of using the paperclip. Expected: it attaches the same way.

- [ ] **Step 5: Remove an attachment**

Click the "×" on one chip. Send a new message asking about that specific file's content. Expected: the chip disappears immediately, and the model no longer has that file's content (a question only it could answer should now get an "I don't have that information" type response).

- [ ] **Step 6: Size cap rejection**

Attach a file (or several) whose combined extracted text exceeds 50,000 characters — e.g. a very large text file. Expected: a clear red error naming the character limit appears; the file is not attached; no chip is added.

- [ ] **Step 7: Unsupported/corrupt file rejection**

Try attaching an image file (e.g. a `.png`) or a deliberately corrupted document. Expected: a clear error message, no crash, no chip added.

- [ ] **Step 8: Persistence across restart**

Quit and relaunch the app, reopen the same conversation. Expected: previously-attached files still show as chips (fetched fresh from the database via `loadAttachments()`).

- [ ] **Step 9: Final full-suite confirmation**

```bash
cd "AIChatRouterKit" && swift test 2>&1 | tail -5
```

Expected: all 70 tests pass.
