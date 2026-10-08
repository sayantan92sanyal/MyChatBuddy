import Foundation
import Testing
@testable import AIChatRouterKit

@Suite("AppSettingsStore local model selection")
struct AppSettingsStoreLocalModelSelectionTests {
    private func makeStore() -> AppSettingsStore {
        AppSettingsStore(defaults: UserDefaults(suiteName: "AppSettingsStoreLocalModelSelectionTests-\(UUID().uuidString)")!)
    }

    @Test func textModelIDDefaultsToTheGivenFallback() {
        let store = makeStore()
        #expect(store.loadActiveLocalTextModelID(default: "fallback-text") == "fallback-text")
    }

    @Test func textModelIDPersistsACustomValue() {
        let store = makeStore()
        store.saveActiveLocalTextModelID("mlx-community/Qwen2.5-7B-Instruct-4bit")
        #expect(store.loadActiveLocalTextModelID(default: "fallback-text") == "mlx-community/Qwen2.5-7B-Instruct-4bit")
    }

    @Test func visionModelIDDefaultsToTheGivenFallback() {
        let store = makeStore()
        #expect(store.loadActiveLocalVisionModelID(default: "fallback-vision") == "fallback-vision")
    }

    @Test func visionModelIDPersistsACustomValue() {
        let store = makeStore()
        store.saveActiveLocalVisionModelID("mlx-community/Qwen2.5-VL-7B-Instruct-4bit")
        #expect(store.loadActiveLocalVisionModelID(default: "fallback-vision") == "mlx-community/Qwen2.5-VL-7B-Instruct-4bit")
    }
}
