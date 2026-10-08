import Foundation

/// A local MLX model, identified by its Hugging Face repo id (e.g.
/// "mlx-community/Llama-3.2-3B-Instruct-4bit").
public struct LocalModelOption: Sendable, Identifiable, Hashable {
    /// Which MLX factory can load this model: `LLMModelFactory` (text) or
    /// `VLMModelFactory` (vision). Kept here, not inferred from the id, since
    /// nothing about a bare repo id string reveals which factory it needs.
    public enum ModelKind: Sendable {
        case text
        case vision
    }

    public let id: String
    public let displayName: String
    public let kind: ModelKind

    public init(id: String, displayName: String, kind: ModelKind) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
    }
}

/// Swappable catalogs of local MLX models, one per kind. Both stay curated,
/// hardcoded lists — no arbitrary Hugging Face repo entry — so every option is
/// guaranteed to actually load via its kind's factory.
public enum LocalModelCatalog {
    public static let llama3_2_3B = LocalModelOption(
        id: "mlx-community/Llama-3.2-3B-Instruct-4bit",
        displayName: "Llama 3.2 3B Instruct (4-bit)",
        kind: .text
    )
    public static let qwen2_5_3B = LocalModelOption(
        id: "mlx-community/Qwen2.5-3B-Instruct-4bit",
        displayName: "Qwen2.5 3B Instruct (4-bit)",
        kind: .text
    )
    public static let qwen2_5_7B = LocalModelOption(
        id: "mlx-community/Qwen2.5-7B-Instruct-4bit",
        displayName: "Qwen2.5 7B Instruct (4-bit)",
        kind: .text
    )
    public static let qwen2_5VL7B = LocalModelOption(
        id: "mlx-community/Qwen2.5-VL-7B-Instruct-4bit",
        displayName: "Qwen2.5-VL 7B Instruct (4-bit)",
        kind: .vision
    )

    public static let textModels: [LocalModelOption] = [llama3_2_3B, qwen2_5_3B, qwen2_5_7B]
    public static let visionModels: [LocalModelOption] = [qwen2_5VL7B]

    public static let defaultText = llama3_2_3B
    public static let defaultVision = qwen2_5VL7B
}
