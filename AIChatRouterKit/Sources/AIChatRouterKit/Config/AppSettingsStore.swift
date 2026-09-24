import Foundation

/// Persists app configuration outside the database (UserDefaults-backed): the
/// tier→provider mapping, the usage-limiter config, and routing sensitivity.
public struct AppSettingsStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let tierMappingKey = "com.sayantan.aichatrouter.tierModelMapping"
    private let limiterConfigKey = "com.sayantan.aichatrouter.limiterConfig"
    private let routingSensitivityKey = "com.sayantan.aichatrouter.routingSensitivity"
    private let webSearchEnabledKey = "com.sayantan.aichatrouter.webSearchEnabled"
    private let attachmentSizeCapKey = "com.sayantan.aichatrouter.attachmentSizeCapCharacters"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func loadTierModelMapping(default defaultMapping: TierModelMapping) -> TierModelMapping {
        guard let data = defaults.data(forKey: tierMappingKey),
              let decoded = try? JSONDecoder().decode(TierModelMapping.self, from: data)
        else {
            return defaultMapping
        }
        return decoded
    }

    public func saveTierModelMapping(_ mapping: TierModelMapping) {
        guard let data = try? JSONEncoder().encode(mapping) else { return }
        defaults.set(data, forKey: tierMappingKey)
    }

    public func loadLimiterConfig() -> LimiterConfig {
        guard let data = defaults.data(forKey: limiterConfigKey),
              let decoded = try? JSONDecoder().decode(LimiterConfig.self, from: data)
        else {
            return .disabled
        }
        return decoded
    }

    public func saveLimiterConfig(_ config: LimiterConfig) {
        guard let data = try? JSONEncoder().encode(config) else { return }
        defaults.set(data, forKey: limiterConfigKey)
    }

    public func loadRoutingSensitivity() -> RoutingSensitivity {
        guard let raw = defaults.string(forKey: routingSensitivityKey),
              let sensitivity = RoutingSensitivity(rawValue: raw)
        else {
            return .balanced
        }
        return sensitivity
    }

    public func saveRoutingSensitivity(_ sensitivity: RoutingSensitivity) {
        defaults.set(sensitivity.rawValue, forKey: routingSensitivityKey)
    }

    public func loadWebSearchEnabled() -> Bool {
        guard defaults.object(forKey: webSearchEnabledKey) != nil else { return true }
        return defaults.bool(forKey: webSearchEnabledKey)
    }

    public func saveWebSearchEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: webSearchEnabledKey)
    }

    public func loadAttachmentSizeCapCharacters() -> Int {
        let value = defaults.integer(forKey: attachmentSizeCapKey)
        return value > 0 ? value : AttachmentStore.defaultCharacterLimit
    }

    public func saveAttachmentSizeCapCharacters(_ value: Int) {
        defaults.set(value, forKey: attachmentSizeCapKey)
    }
}
