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

    @Test func saveClampsToTheMaximumAllowedValue() {
        // Routing is attachment-blind (by design), so an oversized attachment can
        // still reach the local model, whose context window is far smaller than
        // any cloud model's — an unbounded setting risks memory pressure/a crash
        // in the local provider. A huge or mistyped value (extra zeros) is
        // clamped rather than accepted as-is.
        let store = makeStore()
        store.saveAttachmentSizeCapCharacters(AppSettingsStore.maxAttachmentSizeCapCharacters + 1_000_000)
        #expect(store.loadAttachmentSizeCapCharacters() == AppSettingsStore.maxAttachmentSizeCapCharacters)
    }

    @Test func saveAllowsExactlyTheMaximumAllowedValue() {
        let store = makeStore()
        store.saveAttachmentSizeCapCharacters(AppSettingsStore.maxAttachmentSizeCapCharacters)
        #expect(store.loadAttachmentSizeCapCharacters() == AppSettingsStore.maxAttachmentSizeCapCharacters)
    }
}
