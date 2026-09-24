import Foundation
import MLXLLM
import MLXLMCommon

/// Downloads (via `HubClientDownloader`, into the shared HF cache) and loads MLX models,
/// caching the resulting `ModelContainer` per model id for the lifetime of the app.
public actor LocalModelManager {
    public enum ModelState: Sendable, Equatable {
        case notDownloaded
        case downloading(Double)
        case ready
        case failed(String)
    }

    private var containers: [String: ModelContainer] = [:]
    private var states: [String: ModelState] = [:]
    private let downloader: any Downloader
    private let tokenizerLoader: any TokenizerLoader

    public init(
        downloader: any Downloader = HubClientDownloader(),
        tokenizerLoader: any TokenizerLoader = TransformersTokenizerLoader()
    ) {
        self.downloader = downloader
        self.tokenizerLoader = tokenizerLoader
    }

    public func state(for modelID: String) -> ModelState {
        states[modelID] ?? .notDownloaded
    }

    /// Downloads/loads the given model if needed and returns its `ModelContainer`.
    /// Subsequent calls for the same model id return the cached container immediately.
    public func loadedContainer(
        for modelID: String,
        progressHandler: @Sendable @escaping (Double) -> Void = { _ in }
    ) async throws -> ModelContainer {
        if let existing = containers[modelID] {
            return existing
        }

        states[modelID] = .downloading(0)
        do {
            let container = try await LLMModelFactory.shared.loadContainer(
                from: downloader,
                using: tokenizerLoader,
                configuration: .init(id: modelID),
                progressHandler: { [weak self] progress in
                    let fraction = progress.fractionCompleted
                    progressHandler(fraction)
                    Task { await self?.recordProgress(modelID: modelID, fraction: fraction) }
                }
            )
            containers[modelID] = container
            states[modelID] = .ready
            return container
        } catch {
            states[modelID] = .failed(error.localizedDescription)
            throw error
        }
    }

    private func recordProgress(modelID: String, fraction: Double) {
        if case .ready = states[modelID] { return }
        states[modelID] = .downloading(fraction)
    }
}
