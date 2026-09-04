// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BlackGlass",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "BlackGlass", targets: ["BlackGlass"])
    ],
    targets: [
        .executableTarget(
            name: "BlackGlass",
            path: "Sources/BlackGlass",
            resources: [
                .copy("Web")
            ]
        )
    ]
)
