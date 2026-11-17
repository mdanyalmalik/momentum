// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Momentum",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Momentum", targets: ["Momentum"]),
        .library(name: "MomentumCore", targets: ["MomentumCore"]),
    ],
    targets: [
        // Pure-Swift scheduling engine. No UI, no persistence: fully unit-testable.
        .target(name: "MomentumCore"),
        // SwiftUI + SwiftData macOS app.
        .executableTarget(
            name: "Momentum",
            dependencies: ["MomentumCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "MomentumCoreTests", dependencies: ["MomentumCore"]),
    ]
)
