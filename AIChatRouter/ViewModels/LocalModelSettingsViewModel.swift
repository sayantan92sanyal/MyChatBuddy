import Foundation
import Observation
import AIChatRouterKit

@Observable
@MainActor
final class LocalModelSettingsViewModel {
    let kind: LocalModelOption.ModelKind
    let options: [LocalModelOption]
    var selectedModelID: String
    private(set) var isDownloading = false
    private(set) var progress: Double?
    private(set) var statusMessage: String = "Not downloaded yet."

    private let modelManager: LocalModelManager
    private let settingsStore: AppSettingsStore

    init(kind: LocalModelOption.ModelKind, modelManager: LocalModelManager, settingsStore: AppSettingsStore) {
        self.kind = kind
        self.modelManager = modelManager
        self.settingsStore = settingsStore
        switch kind {
        case .text:
            self.options = LocalModelCatalog.textModels
            self.selectedModelID = settingsStore.loadActiveLocalTextModelID(default: LocalModelCatalog.defaultText.id)
        case .vision:
            self.options = LocalModelCatalog.visionModels
            self.selectedModelID = settingsStore.loadActiveLocalVisionModelID(default: LocalModelCatalog.defaultVision.id)
        }
    }

    func save() {
        switch kind {
        case .text: settingsStore.saveActiveLocalTextModelID(selectedModelID)
        case .vision: settingsStore.saveActiveLocalVisionModelID(selectedModelID)
        }
    }

    func refreshStatus() async {
        switch await modelManager.state(for: selectedModelID) {
        case .notDownloaded:
            statusMessage = "Not downloaded yet."
        case .downloading(let fraction):
            statusMessage = "Downloading…"
            progress = fraction
        case .ready:
            statusMessage = "Ready — loaded and cached in ~/.cache/huggingface/hub."
        case .failed(let message):
            statusMessage = "Failed: \(message)"
        }
    }

    func downloadAndLoad() async {
        guard !isDownloading else { return }
        isDownloading = true
        progress = 0
        statusMessage = "Downloading…"

        do {
            _ = try await modelManager.loadedContainer(for: selectedModelID, kind: kind) { [weak self] fraction in
                Task { @MainActor in
                    self?.progress = fraction
                }
            }
            statusMessage = "Ready — loaded and cached in ~/.cache/huggingface/hub."
            progress = 1
        } catch {
            statusMessage = "Failed: \(error.localizedDescription)"
        }

        isDownloading = false
    }
}
