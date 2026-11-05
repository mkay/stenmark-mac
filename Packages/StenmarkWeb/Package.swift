// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "StenmarkWeb",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "StenmarkWeb", targets: ["StenmarkWeb"]),
    ],
    targets: [
        .target(
            name: "StenmarkWeb",
            // Built from web/editor and web/reader with `npm run build`.
            resources: [.copy("Resources/Editor"), .copy("Resources/Reader")]
        ),
        .testTarget(name: "StenmarkWebTests", dependencies: ["StenmarkWeb"]),
    ]
)
