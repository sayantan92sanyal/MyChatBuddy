import Foundation

/// A local MLX model, identified by its Hugging Face repo id (e.g.
/// "mlx-community/Llama-3.2-3B-Instruct-4bit").
public struct LocalModelOption: Sendable, Identifiable, Hashable {
    public let id: String
    public let displayName: String

    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

/// Swappable catalog of local MLX models. Default is Llama 3.2 3B-Instruct (4-bit);
/// Qwen2.5 variants are offered as alternates per the spec's stated assumption.
public enum LocalModelCatalog {
    public static let llama3_2_3B = LocalModelOption(
        id: "mlx-community/Llama-3.2-3B-Instruct-4bit",
        displayName: "Llama 3.2 3B Instruct (4-bit)"
    )
    public static let qwen2_5_3B = LocalModelOption(
        id: "mlx-community/Qwen2.5-3B-Instruct-4bit",
        displayName: "Qwen2.5 3B Instruct (4-bit)"
    )
    public static let qwen2_5_7B = LocalModelOption(
        id: "mlx-community/Qwen2.5-7B-Instruct-4bit",
        displayName: "Qwen2.5 7B Instruct (4-bit)"
    )

    public static let all: [LocalModelOption] = [llama3_2_3B, qwen2_5_3B, qwen2_5_7B]
    public static let `default` = llama3_2_3B
}
