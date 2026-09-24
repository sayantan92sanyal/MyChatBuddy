import Foundation

public struct ModelPrice: Codable, Sendable, Equatable {
    public var inputPerMillionUSD: Double
    public var outputPerMillionUSD: Double

    public init(inputPerMillionUSD: Double, outputPerMillionUSD: Double) {
        self.inputPerMillionUSD = inputPerMillionUSD
        self.outputPerMillionUSD = outputPerMillionUSD
    }

    public func cost(inputTokens: Int, outputTokens: Int) -> Double {
        (Double(inputTokens) / 1_000_000) * inputPerMillionUSD
            + (Double(outputTokens) / 1_000_000) * outputPerMillionUSD
    }
}

/// Provider pricing, kept as plain editable data rather than hardcoded — both
/// Anthropic's and OpenAI's model lineups and per-token rates change over time, and a
/// user should be able to correct this without a code change. Ships with placeholder
/// defaults that should be verified against current provider pricing pages.
public struct PricingTable: Sendable {
    private let fileURL: URL

    public init(fileURL: URL = PricingTable.defaultFileURL()) {
        self.fileURL = fileURL
    }

    public static func defaultFileURL() -> URL {
        let appSupport = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        let dir = appSupport.appendingPathComponent("AIChatRouter", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("pricing.json")
    }

    // Placeholder rates as of this writing — unverified, surface a "verify pricing"
    // prompt in Settings rather than asserting accuracy.
    private static let placeholderDefaults: [String: ModelPrice] = [
        "claude-sonnet-4-5": ModelPrice(inputPerMillionUSD: 3.0, outputPerMillionUSD: 15.0),
        "claude-opus-4-1": ModelPrice(inputPerMillionUSD: 15.0, outputPerMillionUSD: 75.0),
        "gpt-4o-mini": ModelPrice(inputPerMillionUSD: 0.15, outputPerMillionUSD: 0.6),
        "gpt-4o": ModelPrice(inputPerMillionUSD: 2.5, outputPerMillionUSD: 10.0)
    ]

    public func load() -> [String: ModelPrice] {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: ModelPrice].self, from: data)
        else {
            return Self.placeholderDefaults
        }
        return decoded
    }

    public func save(_ table: [String: ModelPrice]) {
        guard let data = try? JSONEncoder().encode(table) else { return }
        try? data.write(to: fileURL)
    }

    public func price(for modelID: String) -> ModelPrice? {
        load()[modelID]
    }

    public func estimatedCost(modelID: String, inputTokens: Int, outputTokens: Int) -> Double {
        guard let price = price(for: modelID) else { return 0 }
        return price.cost(inputTokens: inputTokens, outputTokens: outputTokens)
    }
}
