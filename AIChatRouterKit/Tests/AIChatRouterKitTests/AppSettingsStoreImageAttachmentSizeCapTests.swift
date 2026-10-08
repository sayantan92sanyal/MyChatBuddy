import Foundation
import Testing
@testable import AIChatRouterKit

@Suite("AppSettingsStore image attachment size cap")
struct AppSettingsStoreImageAttachmentSizeCapTests {
    private func makeStore() -> AppSettingsStore {
        AppSettingsStore(defaults: UserDefaults(suiteName: "AppSettingsStoreImageAttachmentSizeCapTests-\(UUID().uuidString)")!)
    }

    @Test func defaultsToTheBuiltInDefault() {
        let store = makeStore()
        #expect(store.loadImageAttachmentSizeCapBytes() == AppSettingsStore.defaultImageAttachmentSizeCapBytes)
    }

    @Test func persistsACustomValue() {
        let store = makeStore()
        store.saveImageAttachmentSizeCapBytes(5_000_000)
        #expect(store.loadImageAttachmentSizeCapBytes() == 5_000_000)
    }

    @Test func zeroOrNegativeSavedValueFallsBackToDefault() {
        let store = makeStore()
        store.saveImageAttachmentSizeCapBytes(0)
        #expect(store.loadImageAttachmentSizeCapBytes() == AppSettingsStore.defaultImageAttachmentSizeCapBytes)
    }

    @Test func saveClampsToTheMaximumAllowedValue() {
        let store = makeStore()
        store.saveImageAttachmentSizeCapBytes(AppSettingsStore.maxImageAttachmentSizeCapBytes + 1_000_000)
        #expect(store.loadImageAttachmentSizeCapBytes() == AppSettingsStore.maxImageAttachmentSizeCapBytes)
    }
}
