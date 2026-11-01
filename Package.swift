// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DroidHub",
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "SimulatorBridge", exclude: ["NOTICE"], linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("IOSurface"), .linkedFramework("CoreVideo"), .linkedFramework("IOKit")]),
        .executableTarget(name: "DroidHub", dependencies: ["SimulatorBridge"], resources: [.process("Resources")], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "DroidHubTests", dependencies: ["DroidHub"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
