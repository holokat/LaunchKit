// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "LaunchKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "LaunchKit", targets: ["LaunchKitApp"]),
        .library(name: "LaunchKitCore", targets: ["LaunchKitCore"]),
        .library(name: "LaunchKitPolicy", targets: ["LaunchKitPolicy"]),
        .library(name: "LaunchKitScanner", targets: ["LaunchKitScanner"]),
        .library(name: "LaunchKitExecution", targets: ["LaunchKitExecution"]),
        .library(name: "LaunchKitSecrets", targets: ["LaunchKitSecrets"]),
        .library(name: "LaunchKitAgentCore", targets: ["LaunchKitAgentCore"]),
        .library(name: "LaunchKitObservability", targets: ["LaunchKitObservability"])
    ],
    targets: [
        .target(name: "LaunchKitCore"),
        .target(
            name: "LaunchKitPolicy",
            dependencies: ["LaunchKitCore"]
        ),
        .target(
            name: "LaunchKitExecution",
            dependencies: ["LaunchKitCore", "LaunchKitPolicy"]
        ),
        .target(
            name: "LaunchKitSecrets",
            dependencies: ["LaunchKitCore"]
        ),
        .target(
            name: "LaunchKitAgentCore",
            dependencies: ["LaunchKitCore", "LaunchKitPolicy"]
        ),
        .target(
            name: "LaunchKitObservability",
            dependencies: ["LaunchKitCore"]
        ),
        .target(
            name: "LaunchKitScanner",
            dependencies: ["LaunchKitCore", "LaunchKitPolicy"]
        ),
        .target(
            name: "LaunchKitDiff",
            dependencies: ["LaunchKitCore", "LaunchKitPolicy"]
        ),
        .target(
            name: "LaunchKitSigning",
            dependencies: ["LaunchKitCore", "LaunchKitExecution", "LaunchKitPolicy"]
        ),
        .target(
            name: "LaunchKitBuild",
            dependencies: ["LaunchKitCore", "LaunchKitExecution", "LaunchKitScanner"]
        ),
        .target(
            name: "LaunchKitAppStoreConnect",
            dependencies: ["LaunchKitCore", "LaunchKitPolicy", "LaunchKitSecrets"]
        ),
        .target(
            name: "LaunchKitPayments",
            dependencies: ["LaunchKitCore", "LaunchKitPolicy"]
        ),
        .target(
            name: "LaunchKitAI",
            dependencies: ["LaunchKitCore", "LaunchKitPolicy"]
        ),
        .target(
            name: "LaunchKitAssets",
            dependencies: ["LaunchKitCore", "LaunchKitPolicy"]
        ),
        .target(
            name: "LaunchKitCompliance",
            dependencies: ["LaunchKitCore", "LaunchKitPolicy"]
        ),
        .target(
            name: "LaunchKitPersistence",
            dependencies: ["LaunchKitCore"]
        ),
        .executableTarget(
            name: "LaunchKitApp",
            dependencies: [
                "LaunchKitAgentCore",
                "LaunchKitAI",
                "LaunchKitAppStoreConnect",
                "LaunchKitAssets",
                "LaunchKitBuild",
                "LaunchKitCompliance",
                "LaunchKitCore",
                "LaunchKitDiff",
                "LaunchKitExecution",
                "LaunchKitPayments",
                "LaunchKitPersistence",
                "LaunchKitPolicy",
                "LaunchKitObservability",
                "LaunchKitScanner",
                "LaunchKitSecrets",
                "LaunchKitSigning"
            ]
        ),
        .testTarget(
            name: "LaunchKitTests",
            dependencies: [
                "LaunchKitAgentCore",
                "LaunchKitAI",
                "LaunchKitBuild",
                "LaunchKitCore",
                "LaunchKitDiff",
                "LaunchKitExecution",
                "LaunchKitObservability",
                "LaunchKitPolicy",
                "LaunchKitScanner",
                "LaunchKitSecrets",
                "LaunchKitSigning"
            ]
        )
    ]
)
