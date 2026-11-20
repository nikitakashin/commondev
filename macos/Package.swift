// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Commondev",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "AgentCore", targets: ["AgentCore"]),
        .executable(name: "commondev-cli", targets: ["CommondevCLI"]),
        .executable(name: "commondev-model", targets: ["CommondevModel"]),
        .executable(name: "CommondevApp", targets: ["CommondevApp"]),
        .executable(name: "commondev-harness", targets: ["CommondevHarness"]),
        .executable(name: "commondev-live", targets: ["CommondevLive"])
    ],
    targets: [
        .target(name: "AgentCore"),
        .target(name: "HarnessCore"),
        .target(name: "Gateway", path: "Sources/Gateway", exclude: ["Resources"]),
        .target(name: "HarnessIntegration", dependencies: ["AgentCore", "HarnessCore"]),
        .executableTarget(name: "CommondevCLI", dependencies: ["AgentCore"], path: "Sources/commondev-cli"),
        .executableTarget(name: "CommondevModel", dependencies: ["AgentCore"], path: "Sources/commondev-model"),
        .executableTarget(name: "CommondevApp", dependencies: ["AgentCore", "Gateway", "HarnessCore", "HarnessIntegration"], path: "Sources/CommondevApp", resources: [.process("Resources")]),
        .executableTarget(name: "CommondevHarness", dependencies: ["AgentCore", "HarnessCore", "HarnessIntegration"], path: "Sources/commondev-harness"),
        .executableTarget(name: "CommondevLive", dependencies: ["AgentCore", "Gateway"], path: "Sources/commondev-live"),
        .testTarget(name: "AgentCoreTests", dependencies: ["AgentCore"]),
        .testTarget(name: "GatewayTests", dependencies: ["Gateway"]),
        .testTarget(name: "HarnessCoreTests", dependencies: ["HarnessCore"]),
        .testTarget(name: "HarnessIntegrationTests", dependencies: ["AgentCore", "HarnessCore", "HarnessIntegration"]),
        .testTarget(name: "CommondevAppTests", dependencies: ["CommondevApp"])
    ]
)
