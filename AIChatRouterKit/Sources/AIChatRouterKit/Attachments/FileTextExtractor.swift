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
    /// Drag-and-drop has no file-type filtering (unlike the picker), so a
    /// multi-gigabyte non-text file can reach `extractPlainText`. Reject by file
    /// size before ever reading the bytes into memory. UTF-8 uses at most 4 bytes
    /// per character, so a file this size or smaller can never decode to more
    /// than `maxPlainTextBytes` characters — a generous ceiling with real margin
    /// above any legitimate attached document's plain-text size.
    public static let maxPlainTextBytes = 20_000_000

    public static func exceedsMaxPlainTextSize(bytes: Int) -> Bool {
        bytes > maxPlainTextBytes
    }

    public init() {}

    public func extractText(from url: URL) async throws -> String {
        let text: String
        switch url.pathExtension.lowercased() {
        case "pdf":
            text = try extractFromPDF(url: url)
        case "docx":
            text = try extractFromDocx(url: url)
        default:
            text = try extractPlainText(url: url)
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AttachmentError.extractionFailed("This file has no extractable text.")
        }
        return text
    }

    private func extractPlainText(url: URL) throws -> String {
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let fileSize = attributes[.size] as? Int,
           Self.exceedsMaxPlainTextSize(bytes: fileSize) {
            throw AttachmentError.extractionFailed("This file is too large to read as text.")
        }
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
