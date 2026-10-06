// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "TiktokenSwiftPort",
    platforms: [.macOS("15.0")],
    products: [
        .library(name: "TiktokenSwiftPort", targets: ["TiktokenSwiftPort"]),
    ],
    targets: [
        .target(
            name: "TiktokenSwiftPort",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "TiktokenSwiftPortTests",
            dependencies: ["TiktokenSwiftPort"],
            resources: [.copy("Fixtures")]
        ),
    ]
)