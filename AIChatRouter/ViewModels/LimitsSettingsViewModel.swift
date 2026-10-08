import Foundation
import Observation
import AIChatRouterKit

@Observable
@MainActor
final class LimitsSettingsViewModel {
    var perConversationSoftCapTokens: String = ""
    var dailyBudgetUSD: String = ""
    var monthlyBudgetUSD: String = ""
    var cloudFastDailyCallCap: String = ""
    var cloudAdvancedDailyCallCap: String = ""
    var attachmentSizeCapCharacters: String = ""
    var imageAttachmentSizeCapBytes: String = ""

    private let settingsStore: AppSettingsStore

    init(settingsStore: AppSettingsStore) {
        self.settingsStore = settingsStore
        let config = settingsStore.loadLimiterConfig()
        perConversationSoftCapTokens = config.perConversationSoftCapTokens.map(String.init) ?? ""
        dailyBudgetUSD = config.dailyBudgetUSD.map { String($0) } ?? ""
        monthlyBudgetUSD = config.monthlyBudgetUSD.map { String($0) } ?? ""
        cloudFastDailyCallCap = config.perTierDailyCallCap[.cloudFast].map(String.init) ?? ""
        cloudAdvancedDailyCallCap = config.perTierDailyCallCap[.cloudAdvanced].map(String.init) ?? ""
        attachmentSizeCapCharacters = String(settingsStore.loadAttachmentSizeCapCharacters())
        imageAttachmentSizeCapBytes = String(settingsStore.loadImageAttachmentSizeCapBytes())
    }

    func save() {
        var perTierDailyCallCap: [ModelTier: Int] = [:]
        if let value = Int(cloudFastDailyCallCap) { perTierDailyCallCap[.cloudFast] = value }
        if let value = Int(cloudAdvancedDailyCallCap) { perTierDailyCallCap[.cloudAdvanced] = value }

        let config = LimiterConfig(
            perConversationSoftCapTokens: Int(perConversationSoftCapTokens),
            dailyBudgetUSD: Double(dailyBudgetUSD),
            monthlyBudgetUSD: Double(monthlyBudgetUSD),
            perTierDailyCallCap: perTierDailyCallCap
        )
        settingsStore.saveLimiterConfig(config)

        if let value = Int(attachmentSizeCapCharacters) {
            settingsStore.saveAttachmentSizeCapCharacters(value)
        }
        if let value = Int(imageAttachmentSizeCapBytes) {
            settingsStore.saveImageAttachmentSizeCapBytes(value)
        }
    }
}
