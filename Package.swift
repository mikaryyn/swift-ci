// swift-tools-version: 5.7

import PackageDescription

let package = Package(
    name: "swift-ci",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "SwiftCI", targets: ["SwiftCI"]),
    ],
    targets: [
        .target(name: "SwiftCI", dependencies: []),
        .testTarget(name: "SwiftCITests", dependencies: ["SwiftCI"]),
     ]
)
