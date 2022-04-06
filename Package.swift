// swift-tools-version: 5.6

import PackageDescription

let package = Package(
    name: "swift-ci",
    platforms: [.macOS(.v12)],
    products: [
        .library(name: "SwiftCI", targets: ["SwiftCI"]),
        .library(name: "Resolver", targets: ["Resolver"])
    ],
    targets: [
        .target(name: "SwiftCI", dependencies: ["Resolver"]),
        .testTarget(name: "SwiftCITests", dependencies: ["SwiftCI"]),
        .target(name: "Resolver")
     ]
)
