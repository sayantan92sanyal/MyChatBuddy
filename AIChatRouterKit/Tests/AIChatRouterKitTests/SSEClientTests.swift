import Foundation
import Testing
@testable import AIChatRouterKit

@Suite("SSEClient")
struct SSEClientTests {
    private func lineStream(_ lines: [String]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            for line in lines { continuation.yield(line) }
            continuation.finish()
        }
    }

    private func byteStream(_ bytes: [UInt8]) -> AsyncThrowingStream<UInt8, Error> {
        AsyncThrowingStream { continuation in
            for byte in bytes { continuation.yield(byte) }
            continuation.finish()
        }
    }

    @Test func parsesMultipleSSEEvents() async throws {
        let lines = [
            "event: content_block_delta",
            "data: {\"type\":\"content_block_delta\",\"delta\":{\"text\":\"Hello\"}}",
            "",
            "event: content_block_delta",
            "data: {\"type\":\"content_block_delta\",\"delta\":{\"text\":\" world\"}}",
            ""
        ]

        var events: [SSEEvent] = []
        for try await event in SSEClient.parse(lines: lineStream(lines)) {
            events.append(event)
        }

        #expect(events.count == 2)
        #expect(events[0].event == "content_block_delta")
        #expect(events[0].data.contains("Hello"))
        #expect(events[1].data.contains("world"))
    }

    @Test func parsesMultiLineDataFields() async throws {
        let lines = ["data: line one", "data: line two", ""]

        var events: [SSEEvent] = []
        for try await event in SSEClient.parse(lines: lineStream(lines)) {
            events.append(event)
        }

        #expect(events.count == 1)
        #expect(events[0].data == "line one\nline two")
    }

    @Test func flushesPendingEventWithoutTrailingBlankLine() async throws {
        let lines = ["data: no trailing blank line"]

        var events: [SSEEvent] = []
        for try await event in SSEClient.parse(lines: lineStream(lines)) {
            events.append(event)
        }

        #expect(events.count == 1)
        #expect(events[0].data == "no trailing blank line")
    }

    @Test func ignoresBlankLinesWithNoPendingData() async throws {
        let lines = ["", "", "data: only event", ""]

        var events: [SSEEvent] = []
        for try await event in SSEClient.parse(lines: lineStream(lines)) {
            events.append(event)
        }

        #expect(events.count == 1)
        #expect(events[0].data == "only event")
    }

    // Regression test for a bug found via a live Anthropic stream: `AsyncBytes.lines`
    // (the built-in Foundation splitter) silently drops blank lines, which collapsed
    // every SSE event in a real response into a single unparseable blob. `lines(from:)`
    // does the byte→line splitting itself specifically so blank lines are never lost.
    // This test exercises that exact boundary (raw bytes in, discrete events out),
    // which prior tests — built from pre-split String arrays — never touched.
    @Test func byteLevelSplittingPreservesBlankLinesAsEventBoundaries() async throws {
        let sse = "event: content_block_delta\r\n" +
            "data: {\"delta\":{\"text\":\"Hi\"}}\r\n" +
            "\r\n" +
            "event: content_block_delta\r\n" +
            "data: {\"delta\":{\"text\":\" there\"}}\r\n" +
            "\r\n"
        let bytes = Array(sse.utf8)

        var events: [SSEEvent] = []
        for try await event in SSEClient.parse(lines: SSEClient.lines(from: byteStream(bytes))) {
            events.append(event)
        }

        #expect(events.count == 2)
        #expect(events[0].data.contains("Hi"))
        #expect(events[1].data.contains("there"))
    }

    @Test func byteLevelSplittingHandlesPlainLFEndings() async throws {
        let sse = "data: line one\ndata: line two\n\n"
        let bytes = Array(sse.utf8)

        var lines: [String] = []
        for try await line in SSEClient.lines(from: byteStream(bytes)) {
            lines.append(line)
        }

        #expect(lines == ["data: line one", "data: line two", ""])
    }
}
