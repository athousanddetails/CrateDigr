// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CrateDigr",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "CrateDigr",
            path: "CrateDigr",
            resources: [
                .copy("Resources/Assets.xcassets"),
                .copy("Resources/Binaries")
            ]
        )
    ]
)
