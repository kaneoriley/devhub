// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DroidHub",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(name: "DroidHub", resources: [.process("Resources")], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "DroidHubTests", dependencies: ["DroidHub"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
