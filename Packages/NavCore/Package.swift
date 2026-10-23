// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NavCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "NavCore", targets: ["NavCore"]),
    ],
    targets: [
        .target(name: "NavCore"),
        .testTarget(name: "NavCoreTests", dependencies: ["NavCore"]),
    ]
)
