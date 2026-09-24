import Foundation

/// Resolves a `ModelTier` (the only thing `QueryRouter` ever outputs) to a concrete
/// provider + model, keeping the router itself provider-agnostic. Reads the current
/// `TierModelMapping` from `AppSettingsStore` on every call, so Settings changes take
/// effect immediately without needing to reconstruct this registry.
public struct ProviderRegistry: Sendable {
    private let providers: [ProviderID: LLMProvider]
    private let localDescriptor: ProviderModelDescriptor
    private let settingsStore: AppSettingsStore
    private let defaultTierModelMapping: TierModelMapping

    public init(
        providers: [ProviderID: LLMProvider],
        localDescriptor: ProviderModelDescriptor,
        settingsStore: AppSettingsStore,
        defaultTierModelMapping: TierModelMapping
    ) {
        self.providers = providers
        self.localDescriptor = localDescriptor
        self.settingsStore = settingsStore
        self.defaultTierModelMapping = defaultTierModelMapping
    }

    public func resolve(tier: ModelTier) -> (provider: LLMProvider, descriptor: ProviderModelDescriptor)? {
        let mapping = settingsStore.loadTierModelMapping(default: defaultTierModelMapping)
        let descriptor: ProviderModelDescriptor
        switch tier {
        case .local:
            descriptor = localDescriptor
        case .cloudFast:
            descriptor = mapping.cloudFast
        case .cloudAdvanced:
            descriptor = mapping.cloudAdvanced
        }
        guard let provider = providers[descriptor.providerID] else { return nil }
        return (provider, descriptor)
    }
}
