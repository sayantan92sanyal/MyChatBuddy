import Foundation
import Testing
@testable import AIChatRouterKit

@Suite("AppSettingsStore web search toggle")
struct AppSettingsStoreWebSearchTests {
    private func makeStore() -> AppSettingsStore {
        let suiteName = "AppSettingsStoreWebSearchTests-\(UUID().uuidString)"
        return AppSettingsStore(defaults: UserDefaults(suiteName: suiteName)!)
    }

    @Test func defaultsToEnabled() {
        let store = makeStore()
        #expect(store.loadWebSearchEnabled() == true)
    }

    @Test func persistsDisabledState() {
        let store = makeStore()
        store.saveWebSearchEnabled(false)
        #expect(store.loadWebSearchEnabled() == false)
    }

    @Test func persistsReenabledState() {
        let store = makeStore()
        store.saveWebSearchEnabled(false)
        store.saveWebSearchEnabled(true)
        #expect(store.loadWebSearchEnabled() == true)
    }
}
