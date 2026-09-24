// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AIChatRouterKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "AIChatRouterKit",
            targets: ["AIChatRouterKit"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.10.0"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", from: "3.31.3"),
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.8.1"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.0.0")
    ],
    targets: [
        .target(
            name: "AIChatRouterKit",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers")
            ]
        ),
        .testTarget(
            name: "AIChatRouterKitTests",
            dependencies: ["AIChatRouterKit"],
            resources: [.copy("Fixtures")]
        )
    ]
)
