import Foundation
import Testing
@testable import AIChatRouterKit

@Suite("ProviderRegistry")
struct ProviderRegistryTests {
    private let textA = LocalModelOption(id: "text-a", displayName: "Text A", kind: .text)
    private let textB = LocalModelOption(id: "text-b", displayName: "Text B", kind: .text)
    private let visionA = LocalModelOption(id: "vision-a", displayName: "Vision A", kind: .vision)

    private func makeSettingsStore() -> AppSettingsStore {
        AppSettingsStore(defaults: UserDefaults(suiteName: "ProviderRegistryTests-\(UUID().uuidString)")!)
    }

    private func makeRegistry(settingsStore: AppSettingsStore) -> ProviderRegistry {
        let mapping = TierModelMapping(
            cloudFast: ProviderModelDescriptor(id: "claude-sonnet-4-5", providerID: .anthropic, tier: .cloudFast, displayName: "Sonnet"),
            cloudAdvanced: ProviderModelDescriptor(id: "claude-opus-4-1", providerID: .anthropic, tier: .cloudAdvanced, displayName: "Opus")
        )
        return ProviderRegistry(
            cloudProviders: [.anthropic: AnthropicProvider()],
            localModelManager: LocalModelManager(),
            settingsStore: settingsStore,
            defaultTierModelMapping: mapping,
            defaultLocalTextModel: textA,
            defaultLocalVisionModel: visionA
        )
    }

    @Test func localTierResolvesToTheDefaultTextModelWhenNothingIsSaved() {
        let registry = makeRegistry(settingsStore: makeSettingsStore())
        let resolved = registry.resolve(tier: .local)
        #expect(resolved?.descriptor.id == "text-a")
        #expect(resolved?.descriptor.providerID == .localMLX)
    }

    @Test func localTierResolvesToTheSavedActiveTextModelAfterSwitching() {
        // The actual dead-wiring fix: switching the setting must be reflected on
        // the very next resolve() call, no restart required.
        let store = makeSettingsStore()
        let registry = makeRegistry(settingsStore: store)
        store.saveActiveLocalTextModelID("text-b")

        let resolved = registry.resolve(tier: .local)
        #expect(resolved?.descriptor.id == "text-b")
        #expect(resolved?.descriptor.providerID == .localMLX)
    }

    @Test func resolveVisionResolvesToTheDefaultVisionModelWhenNothingIsSaved() {
        let registry = makeRegistry(settingsStore: makeSettingsStore())
        let resolved = registry.resolveVision()
        #expect(resolved.descriptor.id == "vision-a")
        #expect(resolved.descriptor.providerID == .localVLM)
    }

    @Test func resolveVisionResolvesToTheSavedActiveVisionModelAfterSwitching() {
        let store = makeSettingsStore()
        let registry = makeRegistry(settingsStore: store)
        store.saveActiveLocalVisionModelID("vision-b")

        let resolved = registry.resolveVision()
        #expect(resolved.descriptor.id == "vision-b")
        #expect(resolved.descriptor.providerID == .localVLM)
    }

    @Test func cloudTierResolutionIsUnaffectedByTheLocalRewrite() {
        let registry = makeRegistry(settingsStore: makeSettingsStore())
        let resolved = registry.resolve(tier: .cloudFast)
        #expect(resolved?.descriptor.id == "claude-sonnet-4-5")
        #expect(resolved?.descriptor.providerID == .anthropic)
    }

    @Test func isLocalModelReadyIsFalseForAModelThatHasNeverBeenLoaded() async {
        let registry = makeRegistry(settingsStore: makeSettingsStore())
        #expect(await registry.isLocalModelReady(kind: .vision) == false)
    }
}
