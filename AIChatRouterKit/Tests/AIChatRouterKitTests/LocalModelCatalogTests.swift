import Testing
@testable import AIChatRouterKit

@Suite("LocalModelCatalog")
struct LocalModelCatalogTests {
    @Test func everyTextModelHasTextKind() {
        #expect(!LocalModelCatalog.textModels.isEmpty)
        #expect(LocalModelCatalog.textModels.allSatisfy { $0.kind == .text })
    }

    @Test func everyVisionModelHasVisionKind() {
        #expect(!LocalModelCatalog.visionModels.isEmpty)
        #expect(LocalModelCatalog.visionModels.allSatisfy { $0.kind == .vision })
    }

    @Test func defaultTextIsInTheTextCatalog() {
        #expect(LocalModelCatalog.textModels.contains(LocalModelCatalog.defaultText))
    }

    @Test func defaultVisionIsInTheVisionCatalog() {
        #expect(LocalModelCatalog.visionModels.contains(LocalModelCatalog.defaultVision))
    }

    @Test func visionCatalogIncludesTheVerifiedQwenModel() {
        #expect(LocalModelCatalog.visionModels.contains { $0.id == "mlx-community/Qwen2.5-VL-7B-Instruct-4bit" })
    }
}
