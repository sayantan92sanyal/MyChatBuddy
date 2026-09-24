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

    @Test func throwsExtractionFailedForEmptyPlainTextFile() async throws {
        // A file that "extracts" successfully but has no actual content must not
        // be attached as if it were a real document — same principle as the PDF
        // scanned-image case, just for the plain-text path.
        await #expect(throws: AttachmentError.self) {
            _ = try await FileTextExtractor().extractText(from: try fixture("fixture-empty.txt"))
        }
    }

    @Test func throwsExtractionFailedForWhitespaceOnlyPlainTextFile() async throws {
        await #expect(throws: AttachmentError.self) {
            _ = try await FileTextExtractor().extractText(from: try fixture("fixture-whitespace-only.txt"))
        }
    }

    @Test func throwsExtractionFailedForEmptyDocx() async throws {
        await #expect(throws: AttachmentError.self) {
            _ = try await FileTextExtractor().extractText(from: try fixture("fixture-empty.docx"))
        }
    }

    @Test func rejectsPlainTextFilesTooLargeToSafelyReadIntoMemory() {
        // Drag-and-drop has no type filtering (unlike the file picker), so a
        // multi-gigabyte non-text file can reach extractPlainText. This must be
        // rejected by file size before ever reading the bytes into memory — a
        // pure size check, tested without needing an actual giant fixture file.
        #expect(FileTextExtractor.exceedsMaxPlainTextSize(bytes: FileTextExtractor.maxPlainTextBytes) == false)
        #expect(FileTextExtractor.exceedsMaxPlainTextSize(bytes: FileTextExtractor.maxPlainTextBytes + 1) == true)
    }
}
