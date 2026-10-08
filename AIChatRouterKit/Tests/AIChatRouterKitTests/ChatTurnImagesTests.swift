import Foundation
import Testing
@testable import AIChatRouterKit

@Suite("ChatTurn images field")
struct ChatTurnImagesTests {
    @Test func defaultsToAnEmptyImagesArray() {
        let turn = ChatTurn(role: .user, content: "hello")
        #expect(turn.images.isEmpty)
    }

    @Test func canBeConstructedWithImageData() {
        let data = Data([0x01, 0x02, 0x03])
        let turn = ChatTurn(role: .user, content: "what is this?", images: [data])
        #expect(turn.images == [data])
    }

    @Test func providerIDIncludesLocalVLM() {
        #expect(ProviderID.allCases.contains(.localVLM))
    }
}
