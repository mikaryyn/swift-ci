// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SampleApp",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "SampleKit", targets: ["SampleKit"]),
    ],
    targets: [
        .target(name: "SampleKit"),
        .testTarget(name: "SampleXCTests", dependencies: ["SampleKit"]),
        .testTarget(name: "SampleSwiftTestingTests", dependencies: ["SampleKit"]),
    ]
)
