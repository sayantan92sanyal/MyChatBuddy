import Foundation

public struct SSEEvent: Sendable {
    public let event: String?
    public let data: String
}

/// Minimal Server-Sent Events line-parser over `URLSession.bytes(for:)`, shared by
/// `AnthropicProvider` and `OpenAIProvider` so streaming/parsing logic lives in one place.
public struct SSEClient: Sendable {
    public init() {}

    public func events(
        for request: URLRequest,
        session: URLSession = .shared
    ) -> AsyncThrowingStream<SSEEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request)

                    if let httpResponse = response as? HTTPURLResponse,
                       !(200..<300).contains(httpResponse.statusCode) {
                        var body = ""
                        for try await line in Self.lines(from: bytes) {
                            body += line
                        }
                        throw ProviderError.network("HTTP \(httpResponse.statusCode): \(body)")
                    }

                    for try await event in Self.parse(lines: Self.lines(from: bytes)) {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Splits a raw byte stream into lines ourselves rather than relying on
    /// `AsyncBytes.lines`: that built-in splitter silently drops blank lines, which is
    /// fatal for SSE, whose event boundaries *are* blank lines — verified against a live
    /// Anthropic stream, where it collapsed an entire multi-event response into one
    /// unparseable blob. Handles both "\n" and "\r\n" line endings. Generic over the byte
    /// sequence so it's unit-testable without a live URLSession.
    static func lines<B: AsyncSequence & Sendable>(
        from bytes: B
    ) -> AsyncThrowingStream<String, Error> where B.Element == UInt8 {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var buffer: [UInt8] = []
                    for try await byte in bytes {
                        if byte == UInt8(ascii: "\n") {
                            if buffer.last == UInt8(ascii: "\r") { buffer.removeLast() }
                            continuation.yield(String(decoding: buffer, as: UTF8.self))
                            buffer.removeAll(keepingCapacity: true)
                        } else {
                            buffer.append(byte)
                        }
                    }
                    if !buffer.isEmpty {
                        continuation.yield(String(decoding: buffer, as: UTF8.self))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Parses SSE events from any async sequence of lines. Split out from `events(for:session:)`
    /// so the parsing algorithm itself is testable without a live or mocked URLSession.
    static func parse<S: AsyncSequence & Sendable>(
        lines: S
    ) -> AsyncThrowingStream<SSEEvent, Error> where S.Element == String {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var eventType: String?
                    var dataLines: [String] = []
                    for try await line in lines {
                        if line.isEmpty {
                            if !dataLines.isEmpty {
                                continuation.yield(SSEEvent(event: eventType, data: dataLines.joined(separator: "\n")))
                            }
                            eventType = nil
                            dataLines = []
                        } else if line.hasPrefix("event:") {
                            eventType = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                        } else if line.hasPrefix("data:") {
                            dataLines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
                        }
                    }
                    // Flush a trailing event even if the stream ended without a final blank
                    // line separator (some producers close the connection without one).
                    if !dataLines.isEmpty {
                        continuation.yield(SSEEvent(event: eventType, data: dataLines.joined(separator: "\n")))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
