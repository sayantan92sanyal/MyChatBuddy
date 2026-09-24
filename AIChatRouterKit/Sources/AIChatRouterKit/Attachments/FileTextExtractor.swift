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
