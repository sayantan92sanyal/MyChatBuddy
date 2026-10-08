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
    private let cacheDirectory: URL

    public init(
        downloader: any Downloader = HubClientDownloader(),
        tokenizerLoader: any TokenizerLoader = TransformersTokenizerLoader(),
        cacheDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub")
    ) {
        self.downloader = downloader
        self.tokenizerLoader = tokenizerLoader
        self.cacheDirectory = cacheDirectory
    }

    /// In-memory state wins; otherwise a model whose weights are already in the
    /// shared HF cache counts as `.ready` — `states` is empty on every launch, and
    /// without this a previously downloaded model would read "not downloaded"
    /// after each relaunch. Loading it is a local read, not a download.
    public func state(for modelID: String) -> ModelState {
        if let known = states[modelID] { return known }
        return isCachedOnDisk(modelID) ? .ready : .notDownloaded
    }

    private func isCachedOnDisk(_ modelID: String) -> Bool {
        let snapshots = cacheDirectory
            .appendingPathComponent("models--" + modelID.replacingOccurrences(of: "/", with: "--"))
            .appendingPathComponent("snapshots")
        guard let revisions = try? FileManager.default.contentsOfDirectory(atPath: snapshots.path) else { return false }
        return revisions.contains { revision in
            let files = (try? FileManager.default.contentsOfDirectory(
                atPath: snapshots.appendingPathComponent(revision).path
            )) ?? []
            return files.contains { $0.hasSuffix(".safetensors") }
        }
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
