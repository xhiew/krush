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
            targets: ["KRCore", "KRWire"]
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
        )
    ]
)
