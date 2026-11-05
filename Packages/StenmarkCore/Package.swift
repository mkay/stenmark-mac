// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "StenmarkCore",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "StenmarkCore", targets: ["StenmarkCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.0.0"),
    ],
    targets: [
        .target(
            name: "StenmarkCore",
            dependencies: ["Yams"],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "StenmarkCoreTests",
            dependencies: ["StenmarkCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
