import Foundation
import AIChatRouterKit

/// A selectable (provider, model) pair for one cloud tier, offered in
/// `TierProviderMappingView`. Model IDs are placeholders — Phase 7 makes these
/// user-editable in Settings rather than hardcoded, since provider lineups/pricing
/// change frequently.
struct TierProviderOption: Identifiable, Hashable {
    let id: String
    let descriptor: ProviderModelDescriptor
}

@MainActor
final class AppEnvironment {
    let database: AppDatabase
    let conversationStore: ConversationStore
    let messageStore: MessageStore
    let routingLogStore: RoutingLogStore
    let usageStore: UsageStore
    let attachmentStore: AttachmentStore
    let imageAttachmentStore: ImageAttachmentStore

    let localModelManager: LocalModelManager
    let settingsStore: AppSettingsStore

    let cloudFastOptions: [TierProviderOption]
    let cloudAdvancedOptions: [TierProviderOption]
    let defaultTierModelMapping: TierModelMapping

    let providerRegistry: ProviderRegistry
    let routingCoordinator: RoutingCoordinator
    let usageLimiter: UsageLimiter
    let networkStatusMonitor: NetworkStatusMonitor

    init(database: AppDatabase) {
        self.database = database
        self.conversationStore = ConversationStore(database: database)
        self.messageStore = MessageStore(database: database)
        self.routingLogStore = RoutingLogStore(database: database)
        self.usageStore = UsageStore(database: database)
        self.attachmentStore = AttachmentStore(database: database)
        self.imageAttachmentStore = ImageAttachmentStore(database: database)
        self.settingsStore = AppSettingsStore()

        let localModelManager = LocalModelManager()
        self.localModelManager = localModelManager

        let cloudProviders: [ProviderID: LLMProvider] = [
            .anthropic: AnthropicProvider(),
            .openAI: OpenAIProvider()
        ]

        self.cloudFastOptions = [
            TierProviderOption(
                id: "anthropic-sonnet",
                descriptor: ProviderModelDescriptor(
                    id: "claude-sonnet-4-5", providerID: .anthropic, tier: .cloudFast, displayName: "Sonnet"
                )
            ),
            TierProviderOption(
                id: "openai-gpt4o-mini",
                descriptor: ProviderModelDescriptor(
                    id: "gpt-4o-mini", providerID: .openAI, tier: .cloudFast, displayName: "GPT-4o mini"
                )
            )
        ]
        self.cloudAdvancedOptions = [
            TierProviderOption(
                id: "anthropic-opus",
                descriptor: ProviderModelDescriptor(
                    id: "claude-opus-4-1", providerID: .anthropic, tier: .cloudAdvanced, displayName: "Opus"
                )
            ),
            TierProviderOption(
                id: "openai-gpt4o",
                descriptor: ProviderModelDescriptor(
                    id: "gpt-4o", providerID: .openAI, tier: .cloudAdvanced, displayName: "GPT-4o"
                )
            )
        ]
        self.defaultTierModelMapping = TierModelMapping(
            cloudFast: cloudFastOptions[0].descriptor,
            cloudAdvanced: cloudAdvancedOptions[0].descriptor
        )

        self.providerRegistry = ProviderRegistry(
            cloudProviders: cloudProviders,
            localModelManager: localModelManager,
            settingsStore: settingsStore,
            defaultTierModelMapping: defaultTierModelMapping,
            defaultLocalTextModel: LocalModelCatalog.defaultText,
            defaultLocalVisionModel: LocalModelCatalog.defaultVision
        )

        let usageLimiter = DefaultUsageLimiter(usageStore: usageStore, settingsStore: settingsStore)
        self.usageLimiter = usageLimiter
        self.networkStatusMonitor = NetworkStatusMonitor()

        self.routingCoordinator = RoutingCoordinator(
            router: PromptedLocalQueryRouter(
                modelManager: localModelManager,
                modelID: LocalModelCatalog.defaultText.id
            ),
            logStore: routingLogStore,
            usageLimiter: usageLimiter,
            networkStatus: NWPathMonitorNetworkStatus(),
            settingsStore: settingsStore
        )
    }

    /// Maps a persisted `Message.modelID` back to a friendly badge label. Checks
    /// both local catalogs (not just "the" local model) since the active local
    /// model can change over time — older messages keep whichever model id they
    /// were actually sent with.
    func displayName(forModelID modelID: String) -> String {
        if let match = LocalModelCatalog.textModels.first(where: { $0.id == modelID }) { return match.displayName }
        if let match = LocalModelCatalog.visionModels.first(where: { $0.id == modelID }) { return match.displayName }
        if let match = (cloudFastOptions + cloudAdvancedOptions).first(where: { $0.descriptor.id == modelID }) {
            return match.descriptor.displayName
        }
        return modelID
    }
}
