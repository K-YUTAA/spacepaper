// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SpacePaper",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "SpacePaper", targets: ["SpacePaper"])],
    targets: [
        .target(name: "SpacePaperCore"),
        .executableTarget(name: "SpacePaper", dependencies: ["SpacePaperCore"]),
        .testTarget(name: "SpacePaperCoreTests", dependencies: ["SpacePaperCore"])
    ]
)
