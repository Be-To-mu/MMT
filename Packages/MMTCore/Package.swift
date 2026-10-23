// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MMTCore",
    platforms: [.iOS("18.0"), .macOS("15.0")],
    products: [
        .library(name: "MMTCore", targets: ["MMTCore"]),
    ],
    targets: [
        .target(name: "MMTCore"),
        .testTarget(name: "MMTCoreTests", dependencies: ["MMTCore"]),
    ]
)
