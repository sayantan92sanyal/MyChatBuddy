import Foundation

/// Resolves a `ModelTier` (the only thing `QueryRouter` ever outputs) to a concrete
/// provider + model, keeping the router itself provider-agnostic. Reads the current
/// `TierModelMapping` and the active local text/vision model ids from `AppSettingsStore`
/// on every call, so Settings changes take effect immediately without needing to
/// reconstruct this registry or restart the app.
///
/// The local slots are handled separately from `cloudProviders`: `LocalMLXProvider`
/// bakes its model id into a stored property at construction (unlike the cloud
/// providers, which take their model id as a `streamCompletion` parameter), so a
/// fresh instance is constructed on every resolve call with whichever model id is
/// currently active — cheap, since `LocalModelManager` (a shared actor) caches the
/// expensive part (the loaded `ModelContainer`) by model id internally.
public struct ProviderRegistry: Sendable {
    private let cloudProviders: [ProviderID: LLMProvider]
    private let localModelManager: LocalModelManager
    private let settingsStore: AppSettingsStore
    private let defaultTierModelMapping: TierModelMapping
    private let defaultLocalTextModel: LocalModelOption
    private let defaultLocalVisionModel: LocalModelOption

    public init(
        cloudProviders: [ProviderID: LLMProvider],
        localModelManager: LocalModelManager,
        settingsStore: AppSettingsStore,
        defaultTierModelMapping: TierModelMapping,
        defaultLocalTextModel: LocalModelOption,
        defaultLocalVisionModel: LocalModelOption
    ) {
        self.cloudProviders = cloudProviders
        self.localModelManager = localModelManager
        self.settingsStore = settingsStore
        self.defaultTierModelMapping = defaultTierModelMapping
        self.defaultLocalTextModel = defaultLocalTextModel
        self.defaultLocalVisionModel = defaultLocalVisionModel
    }

    public func resolve(tier: ModelTier) -> (provider: LLMProvider, descriptor: ProviderModelDescriptor)? {
        switch tier {
        case .local:
            let modelID = settingsStore.loadActiveLocalTextModelID(default: defaultLocalTextModel.id)
            let displayName = LocalModelCatalog.textModels.first(where: { $0.id == modelID })?.displayName
                ?? defaultLocalTextModel.displayName
            let provider = LocalMLXProvider(modelManager: localModelManager, modelID: modelID, kind: .text)
            let descriptor = ProviderModelDescriptor(id: modelID, providerID: .localMLX, tier: .local, displayName: displayName)
            return (provider, descriptor)
        case .cloudFast:
            let mapping = settingsStore.loadTierModelMapping(default: defaultTierModelMapping)
            guard let provider = cloudProviders[mapping.cloudFast.providerID] else { return nil }
            return (provider, mapping.cloudFast)
        case .cloudAdvanced:
            let mapping = settingsStore.loadTierModelMapping(default: defaultTierModelMapping)
            guard let provider = cloudProviders[mapping.cloudAdvanced.providerID] else { return nil }
            return (provider, mapping.cloudAdvanced)
        }
    }

    /// Resolves the dedicated local vision slot — never part of `resolve(tier:)`
    /// since attaching an image bypasses tier routing entirely (see
    /// `ChatViewModel.sendMessage`). Always succeeds: unlike a cloud tier, there's
    /// no configuration under which the vision slot has no provider at all.
    public func resolveVision() -> (provider: LLMProvider, descriptor: ProviderModelDescriptor) {
        let modelID = settingsStore.loadActiveLocalVisionModelID(default: defaultLocalVisionModel.id)
        let displayName = LocalModelCatalog.visionModels.first(where: { $0.id == modelID })?.displayName
            ?? defaultLocalVisionModel.displayName
        let provider = LocalMLXProvider(modelManager: localModelManager, modelID: modelID, kind: .vision)
        let descriptor = ProviderModelDescriptor(id: modelID, providerID: .localVLM, tier: .local, displayName: displayName)
        return (provider, descriptor)
    }

    /// Whether the currently-active model for the given kind has finished
    /// downloading and loading. Used to fail fast with a clear message rather than
    /// triggering a multi-GB download mid-chat (see `ChatViewModel.sendMessage`).
    public func isLocalModelReady(kind: LocalModelOption.ModelKind) async -> Bool {
        let modelID: String
        switch kind {
        case .text: modelID = settingsStore.loadActiveLocalTextModelID(default: defaultLocalTextModel.id)
        case .vision: modelID = settingsStore.loadActiveLocalVisionModelID(default: defaultLocalVisionModel.id)
        }
        if case .ready = await localModelManager.state(for: modelID) { return true }
        return false
    }
}
