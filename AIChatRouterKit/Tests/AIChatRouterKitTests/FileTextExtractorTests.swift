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
