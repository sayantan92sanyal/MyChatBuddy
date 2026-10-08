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
    private let activeLocalTextModelIDKey = "com.sayantan.aichatrouter.activeLocalTextModelID"
    private let activeLocalVisionModelIDKey = "com.sayantan.aichatrouter.activeLocalVisionModelID"
    private let imageAttachmentSizeCapKey = "com.sayantan.aichatrouter.imageAttachmentSizeCapBytes"

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

    /// Ceiling on the user-configurable attachment size cap. Routing is
    /// deliberately attachment-blind (see spec), so an oversized attachment can
    /// still be sent to the local model, whose context window is far smaller
    /// than any cloud model's — an unbounded setting risks memory pressure or a
    /// crash in the local provider. 2,000,000 characters comfortably covers real
    /// large documents (a 620,000-character PDF was the case that motivated
    /// making this configurable) while still rejecting a wildly mistyped value.
    public static let maxAttachmentSizeCapCharacters = 2_000_000

    public func loadAttachmentSizeCapCharacters() -> Int {
        let value = defaults.integer(forKey: attachmentSizeCapKey)
        return value > 0 ? value : AttachmentStore.defaultCharacterLimit
    }

    public func saveAttachmentSizeCapCharacters(_ value: Int) {
        let clamped = min(value, Self.maxAttachmentSizeCapCharacters)
        defaults.set(clamped, forKey: attachmentSizeCapKey)
    }

    public func loadActiveLocalTextModelID(default defaultID: String) -> String {
        defaults.string(forKey: activeLocalTextModelIDKey) ?? defaultID
    }

    public func saveActiveLocalTextModelID(_ id: String) {
        defaults.set(id, forKey: activeLocalTextModelIDKey)
    }

    public func loadActiveLocalVisionModelID(default defaultID: String) -> String {
        defaults.string(forKey: activeLocalVisionModelIDKey) ?? defaultID
    }

    public func saveActiveLocalVisionModelID(_ id: String) {
        defaults.set(id, forKey: activeLocalVisionModelIDKey)
    }

    /// Ceiling on the *source* image file, checked before any downscaling —
    /// downscaling still costs CPU/memory proportional to the source size, so this
    /// guards against an absurdly large file (e.g. an uncompressed RAW photo) before
    /// that work even starts. 10MB comfortably covers real photos from any modern
    /// camera or screenshot.
    public static let defaultImageAttachmentSizeCapBytes = 10_000_000
    public static let maxImageAttachmentSizeCapBytes = 50_000_000

    public func loadImageAttachmentSizeCapBytes() -> Int {
        let value = defaults.integer(forKey: imageAttachmentSizeCapKey)
        return value > 0 ? value : Self.defaultImageAttachmentSizeCapBytes
    }

    public func saveImageAttachmentSizeCapBytes(_ value: Int) {
        let clamped = min(value, Self.maxImageAttachmentSizeCapBytes)
        defaults.set(clamped, forKey: imageAttachmentSizeCapKey)
    }
}
