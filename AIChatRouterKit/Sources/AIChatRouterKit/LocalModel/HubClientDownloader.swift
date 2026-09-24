import Foundation
import HuggingFace
import MLXLMCommon

/// Bridges `HubClient` (from huggingface/swift-huggingface) into mlx-swift-lm's
/// `Downloader` protocol. `HubClient.default` resolves to the standard shared cache
/// (`~/.cache/huggingface/hub` when unsandboxed), satisfying the requirement that model
/// weights be reusable by other MLX tools without going through this app.
public struct HubClientDownloader: Downloader, Sendable {
    private let client: HubClient

    public init(client: HubClient = .default) {
        self.client = client
    }

    public func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        try await client.downloadSnapshot(
            of: Repo.ID(stringLiteral: id),
            revision: revision ?? "main",
            matching: patterns,
            localFilesOnly: false,
            progressHandler: { progress in
                progressHandler(progress)
            }
        )
    }
}
