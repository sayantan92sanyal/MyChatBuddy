import Foundation
import Testing
@testable import AIChatRouterKit

@Suite("LocalModelManager disk cache")
struct LocalModelManagerDiskCacheTests {
    private func makeCacheDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeSnapshot(in cache: URL, modelID: String, files: [String]) throws {
        let snapshot = cache
            .appendingPathComponent("models--" + modelID.replacingOccurrences(of: "/", with: "--"))
            .appendingPathComponent("snapshots/abc123")
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        for file in files {
            FileManager.default.createFile(atPath: snapshot.appendingPathComponent(file).path, contents: Data([0]))
        }
    }

    @Test func aModelAlreadyOnDiskReportsReadyOnAFreshLaunch() async throws {
        let cache = try makeCacheDir()
        try writeSnapshot(in: cache, modelID: "org/model", files: ["config.json", "model-00001-of-00002.safetensors"])
        let manager = LocalModelManager(cacheDirectory: cache)
        #expect(await manager.state(for: "org/model") == .ready)
    }

    @Test func aModelWithNoSnapshotReportsNotDownloaded() async throws {
        let manager = LocalModelManager(cacheDirectory: try makeCacheDir())
        #expect(await manager.state(for: "org/model") == .notDownloaded)
    }

    @Test func aSnapshotWithoutWeightsDoesNotCountAsDownloaded() async throws {
        let cache = try makeCacheDir()
        try writeSnapshot(in: cache, modelID: "org/model", files: ["config.json"])
        let manager = LocalModelManager(cacheDirectory: cache)
        #expect(await manager.state(for: "org/model") == .notDownloaded)
    }
}
