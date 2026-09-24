import Foundation
import Observation
import AIChatRouterKit

@Observable
@MainActor
final class LocalModelSettingsViewModel {
    let options: [LocalModelOption] = LocalModelCatalog.all
    var selectedModelID: String = LocalModelCatalog.default.id
    private(set) var isDownloading = false
    private(set) var progress: Double?
    private(set) var statusMessage: String = "Not downloaded yet."

    private let modelManager: LocalModelManager

    init(modelManager: LocalModelManager) {
        self.modelManager = modelManager
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
            _ = try await modelManager.loadedContainer(for: selectedModelID) { [weak self] fraction in
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
