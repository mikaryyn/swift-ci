// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "swift-ci",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "SwiftCI", targets: ["SwiftCI"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "SwiftCI",
            dependencies: [],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(
            name: "SwiftCITests",
            dependencies: ["SwiftCI"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        )
     ]
)
