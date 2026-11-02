// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DevHub",
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "BuildIdentity"),
        .executableTarget(name: "BuildInfoTool", dependencies: ["BuildIdentity"], path: "Tools/BuildInfo"),
        .target(
            name: "SimulatorBridge",
            path: "Sources/DevHub/Apple/SimulatorBridge",
            exclude: ["NOTICE"],
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("IOSurface"), .linkedFramework("CoreVideo"), .linkedFramework("IOKit")]
        ),
        .executableTarget(
            name: "DevHub",
            dependencies: ["SimulatorBridge", "BuildIdentity"],
            exclude: ["Apple/SimulatorBridge"],
            resources: [.process("Resources"), .process("Apple/Resources"), .process("Android/Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "DevHubTests", dependencies: ["DevHub", "BuildIdentity"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
