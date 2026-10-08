import Testing
@testable import AIChatRouterKit

@Suite("ThinkingStripper")
struct ThinkingStripperTests {
    private func run(_ chunks: [String]) -> String {
        var stripper = ThinkingStripper()
        var out = ""
        for chunk in chunks { out += stripper.feed(chunk) }
        out += stripper.finish()
        return out
    }

    @Test func dropsEverythingUpToTheClosingThinkTag() {
        #expect(run(["Let me look.\n</think>\n\nA red square."]) == "A red square.")
    }

    @Test func handlesTheClosingTagSplitAcrossChunks() {
        #expect(run(["reasoning </th", "ink>\n\nAnswer", " here"]) == "Answer here")
    }

    @Test func emitsLaterChunksImmediatelyOnceThinkingEnded() {
        var stripper = ThinkingStripper()
        #expect(stripper.feed("thinking</think>Hi") == "Hi")
        #expect(stripper.feed(" there") == " there")
    }

    @Test func passesEverythingThroughWhenTheModelNeverThinks() {
        #expect(run(["No tags ", "at all."]) == "No tags at all.")
    }

    @Test func holdsBackTextWhileStillThinking() {
        var stripper = ThinkingStripper()
        #expect(stripper.feed("still reasoning") == "")
    }
}
