// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SnappedCut",
    platforms: [.macOS(.v13), .iOS(.v16), .tvOS(.v16), .watchOS(.v9), .visionOS(.v1)],
    products: [
        .library(name: "SnappedCut", targets: ["SnappedCut"])
    ],
    targets: [
        // No dependencies: URLSession and Foundation, so this adds nothing to an
        // app that already links Foundation.
        .target(name: "SnappedCut"),
        .testTarget(name: "SnappedCutTests", dependencies: ["SnappedCut"])
    ]
)
