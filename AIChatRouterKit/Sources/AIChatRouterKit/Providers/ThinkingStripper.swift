import Foundation

/// Removes a reasoning model's chain-of-thought from a streamed reply. Thinking
/// models (e.g. Qwen3-VL-Thinking) have the opening `<think>` supplied by their
/// chat template, so the stream is reasoning, then `</think>`, then the answer.
/// Text is held back until the closing tag arrives; if the stream ends without
/// one, `finish()` releases everything so a reply is never lost.
public struct ThinkingStripper: Sendable {
    private static let closingTag = "</think>"
    private var buffer = ""
    private var thinkingEnded = false

    public init() {}

    public mutating func feed(_ delta: String) -> String {
        if thinkingEnded { return delta }
        buffer += delta
        guard let range = buffer.range(of: Self.closingTag) else { return "" }
        thinkingEnded = true
        let answer = buffer[range.upperBound...].drop(while: { $0.isWhitespace })
        buffer = ""
        return String(answer)
    }

    public mutating func finish() -> String {
        defer { buffer = "" }
        return thinkingEnded ? "" : buffer
    }
}
