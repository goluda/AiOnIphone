// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenAICompat",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "OpenAICompat", targets: ["OpenAICompat"])],
    targets: [
        .target(name: "OpenAICompat"),
        .testTarget(name: "OpenAICompatTests", dependencies: ["OpenAICompat"]),
    ]
)
