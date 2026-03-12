// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "AgentPulse",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "AgentPulseLib", targets: ["AgentPulseLib"]),
    ],
    targets: [
        .target(
            name: "AgentPulseLib",
            path: "Sources/AgentPulseLib"
        ),
        .executableTarget(
            name: "AgentPulse",
            dependencies: ["AgentPulseLib"],
            path: "Sources/AgentPulse",
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        .testTarget(
            name: "AgentPulseTests",
            dependencies: ["AgentPulseLib"],
            path: "Tests/AgentPulseTests"
        ),
    ]
)
