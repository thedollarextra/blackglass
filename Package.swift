// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LiquidNotes",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "LiquidNotes", targets: ["LiquidNotes"])
    ],
    targets: [
        .executableTarget(
            name: "LiquidNotes",
            path: "Sources/LiquidNotes",
            resources: [
                .copy("Web")
            ]
        )
    ]
)
