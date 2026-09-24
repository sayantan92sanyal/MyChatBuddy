import Foundation

/// Independent per-tier provider selection: cloud-fast and cloud-advanced each
/// resolve to their own provider + model, configurable separately in Settings
/// (e.g. cloud-fast -> OpenAI GPT-4o-mini, cloud-advanced -> Anthropic Opus).
/// The local tier always resolves to the active `LocalModelCatalog` entry.
public struct TierModelMapping: Codable, Sendable, Equatable {
    public var cloudFast: ProviderModelDescriptor
    public var cloudAdvanced: ProviderModelDescriptor

    public init(cloudFast: ProviderModelDescriptor, cloudAdvanced: ProviderModelDescriptor) {
        self.cloudFast = cloudFast
        self.cloudAdvanced = cloudAdvanced
    }
}
