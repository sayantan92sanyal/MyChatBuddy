import Foundation
import MLXLLM
import MLXVLM
import MLXLMCommon

/// Downloads (via `HubClientDownloader`, into the shared HF cache) and loads MLX models,
/// caching the resulting `ModelContainer` per model id for the lifetime of the app.
/// Serves both local slots (text via `LLMModelFactory`, vision via `VLMModelFactory`) —
/// both factories produce the same `ModelContainer` type, so one manager/cache serves
/// both; `kind` only selects which factory populates it.
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
        kind: LocalModelOption.ModelKind,
        progressHandler: @Sendable @escaping (Double) -> Void = { _ in }
    ) async throws -> ModelContainer {
        if let existing = containers[modelID] {
            return existing
        }

        states[modelID] = .downloading(0)
        do {
            let container = try await Self.factory(for: kind).loadContainer(
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

    /// Pure dispatch, kept as a static func so it's testable by factory identity
    /// without needing a real download — `LLMModelFactory.shared`/`VLMModelFactory.shared`
    /// are both singletons of distinct final classes that produce the same
    /// `ModelContainer` type (verified against the vendored mlx-swift-lm package).
    static func factory(for kind: LocalModelOption.ModelKind) -> any ModelFactory {
        switch kind {
        case .text: return LLMModelFactory.shared
        case .vision: return VLMModelFactory.shared
        }
    }

    private func recordProgress(modelID: String, fraction: Double) {
        if case .ready = states[modelID] { return }
        states[modelID] = .downloading(fraction)
    }
}
