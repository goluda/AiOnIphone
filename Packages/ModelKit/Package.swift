// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ModelKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "ModelKit", targets: ["ModelKit"])],
    targets: [
        .target(name: "ModelKit"),
        .testTarget(name: "ModelKitTests", dependencies: ["ModelKit"]),
    ]
)
