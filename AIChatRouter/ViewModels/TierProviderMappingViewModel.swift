import Foundation
import Observation
import AIChatRouterKit

@Observable
@MainActor
final class TierProviderMappingViewModel {
    let fastOptions: [TierProviderOption]
    let advancedOptions: [TierProviderOption]
    var selectedFastID: String
    var selectedAdvancedID: String

    private let settingsStore: AppSettingsStore
    private let defaultMapping: TierModelMapping

    init(
        settingsStore: AppSettingsStore,
        defaultMapping: TierModelMapping,
        fastOptions: [TierProviderOption],
        advancedOptions: [TierProviderOption]
    ) {
        self.settingsStore = settingsStore
        self.defaultMapping = defaultMapping
        self.fastOptions = fastOptions
        self.advancedOptions = advancedOptions

        let current = settingsStore.loadTierModelMapping(default: defaultMapping)
        self.selectedFastID = fastOptions.first(where: { $0.descriptor == current.cloudFast })?.id
            ?? fastOptions.first?.id ?? ""
        self.selectedAdvancedID = advancedOptions.first(where: { $0.descriptor == current.cloudAdvanced })?.id
            ?? advancedOptions.first?.id ?? ""
    }

    func save() {
        guard let fast = fastOptions.first(where: { $0.id == selectedFastID })?.descriptor,
              let advanced = advancedOptions.first(where: { $0.id == selectedAdvancedID })?.descriptor
        else { return }
        settingsStore.saveTierModelMapping(TierModelMapping(cloudFast: fast, cloudAdvanced: advanced))
    }
}
