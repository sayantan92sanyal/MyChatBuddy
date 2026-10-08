import Testing
import MLXLLM
import MLXVLM
@testable import AIChatRouterKit

@Suite("LocalModelManager factory dispatch")
struct LocalModelManagerFactoryDispatchTests {
    @Test func textKindDispatchesToLLMModelFactory() {
        let factory = LocalModelManager.factory(for: .text)
        #expect(factory as AnyObject === LLMModelFactory.shared)
    }

    @Test func visionKindDispatchesToVLMModelFactory() {
        let factory = LocalModelManager.factory(for: .vision)
        #expect(factory as AnyObject === VLMModelFactory.shared)
    }
}
