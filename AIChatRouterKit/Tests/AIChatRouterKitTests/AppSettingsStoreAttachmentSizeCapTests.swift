import Foundation
import Testing
@testable import AIChatRouterKit

@Suite("AppSettingsStore attachment size cap")
struct AppSettingsStoreAttachmentSizeCapTests {
    private func makeStore() -> AppSettingsStore {
        let suiteName = "AppSettingsStoreAttachmentSizeCapTests-\(UUID().uuidString)"
        return AppSettingsStore(defaults: UserDefaults(suiteName: suiteName)!)
    }

    @Test func defaultsToAttachmentStoreDefaultCharacterLimit() {
        let store = makeStore()
        #expect(store.loadAttachmentSizeCapCharacters() == AttachmentStore.defaultCharacterLimit)
    }

    @Test func persistsACustomValue() {
        let store = makeStore()
        store.saveAttachmentSizeCapCharacters(100_000)
        #expect(store.loadAttachmentSizeCapCharacters() == 100_000)
    }

    @Test func zeroOrNegativeSavedValueFallsBackToDefault() {
        // A technical ceiling can't sensibly be "disabled" the way a cost cap
        // can — an invalid/zero saved value must not turn size checking off.
        let store = makeStore()
        store.saveAttachmentSizeCapCharacters(0)
        #expect(store.loadAttachmentSizeCapCharacters() == AttachmentStore.defaultCharacterLimit)
    }
}
