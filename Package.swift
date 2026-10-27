// swift-tools-version: 6.2

import PackageDescription

let moduleSettings: [SwiftSetting] = [.defaultIsolation(MainActor.self)]

let package = Package(
    name: "swift-ci",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "SwiftCI", targets: ["SwiftCI"]),
        .library(name: "SwiftCIXcode", targets: ["SwiftCIXcode"]),
        .library(name: "SwiftCISigning", targets: ["SwiftCISigning"]),
        .library(name: "SwiftCISlack", targets: ["SwiftCISlack"]),
        .library(name: "SwiftCITesting", targets: ["SwiftCITesting"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "SwiftCI",
            dependencies: [],
            swiftSettings: moduleSettings,
        ),
        .target(
            name: "SwiftCIXcode",
            dependencies: ["SwiftCI"],
            swiftSettings: moduleSettings,
        ),
        .target(
            name: "SwiftCISigning",
            dependencies: ["SwiftCI"],
            swiftSettings: moduleSettings,
        ),
        .target(
            name: "SwiftCISlack",
            dependencies: ["SwiftCI"],
            swiftSettings: moduleSettings,
        ),
        .target(
            name: "SwiftCITesting",
            dependencies: ["SwiftCI"],
            swiftSettings: moduleSettings,
        ),
        // Shared helpers for this repository's test targets. Not a product. It uses the SPI of the core, not
        // `@testable import`, so `swift build -c release` also builds it.
        .target(
            name: "SwiftCITestSupport",
            dependencies: ["SwiftCI", "SwiftCITesting"],
            path: "Tests/SwiftCITestSupport",
            swiftSettings: moduleSettings,
        ),
        .testTarget(
            name: "SwiftCITests",
            dependencies: ["SwiftCI", "SwiftCITesting", "SwiftCITestSupport"],
            resources: [.copy("Fixtures")],
            swiftSettings: moduleSettings,
        ),
        .testTarget(
            name: "SwiftCIXcodeTests",
            dependencies: ["SwiftCIXcode", "SwiftCITesting", "SwiftCITestSupport"],
            swiftSettings: moduleSettings,
        ),
        .testTarget(
            name: "SwiftCISigningTests",
            dependencies: ["SwiftCISigning", "SwiftCITesting", "SwiftCITestSupport"],
            swiftSettings: moduleSettings,
        ),
        .testTarget(
            name: "SwiftCISlackTests",
            dependencies: ["SwiftCISlack", "SwiftCITesting", "SwiftCITestSupport"],
            swiftSettings: moduleSettings,
        ),
        // Tests of the public API as an extension author sees it: `import SwiftCI` and `import SwiftCITesting` only.
        .testTarget(
            name: "SwiftCITestingTests",
            dependencies: ["SwiftCI", "SwiftCITesting"],
            swiftSettings: moduleSettings,
        ),
    ]
)
