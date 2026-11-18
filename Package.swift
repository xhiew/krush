// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Krush",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "Krush",
            targets: ["KRCore", "KRWire", "KRTransport", "KRFile"]
        ),
        // Simulated EP device for tests only; never link into an app target.
        .library(
            name: "KRSim",
            targets: ["KRSim"]
        )
    ],
    targets: [
        .target(
            name: "KRCore",
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency")
            ]
        ),
        .target(
            name: "KRWire",
            dependencies: ["KRCore"],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency")
            ]
        ),
        .target(
            name: "KRTransport",
            dependencies: ["KRCore", "KRWire"],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency")
            ]
        ),
        .target(
            name: "KRFile",
            dependencies: ["KRCore", "KRWire", "KRTransport"],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency")
            ]
        ),
        .target(
            name: "KRSim",
            dependencies: ["KRCore", "KRWire", "KRTransport"],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency")
            ]
        ),
        .testTarget(
            name: "KRCoreTests",
            dependencies: ["KRCore"],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency")
            ]
        ),
        .testTarget(
            name: "KRWireTests",
            dependencies: ["KRWire", "KRCore"],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency")
            ]
        ),
        .testTarget(
            name: "KRTransportTests",
            dependencies: ["KRTransport", "KRWire", "KRCore"],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency")
            ]
        ),
        .testTarget(
            name: "KRFileTests",
            dependencies: ["KRFile", "KRSim", "KRTransport", "KRWire", "KRCore"],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency")
            ]
        ),
        .testTarget(
            name: "KRSimTests",
            dependencies: ["KRSim", "KRTransport", "KRWire", "KRCore"],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency")
            ]
        )
    ]
)
