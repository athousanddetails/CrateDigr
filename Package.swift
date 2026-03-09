// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CrateDigr",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .systemLibrary(
            name: "CLibAubio",
            path: "CLibAubio",
            pkgConfig: nil,
            providers: []
        ),
        .executableTarget(
            name: "CrateDigr",
            dependencies: ["CLibAubio"],
            path: "CrateDigr",
            resources: [
                .copy("Resources/Assets.xcassets"),
                .copy("Resources/Binaries")
            ],
            linkerSettings: [
                .unsafeFlags(["-L", "CLibAubio/lib"]),
                .linkedFramework("Accelerate")
            ]
        )
    ]
)
