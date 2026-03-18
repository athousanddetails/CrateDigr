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
        .systemLibrary(
            name: "CLibKeyFinder",
            path: "CLibKeyFinder",
            pkgConfig: nil,
            providers: []
        ),
        .systemLibrary(
            name: "CLibRubberband",
            path: "CLibRubberband",
            pkgConfig: nil,
            providers: []
        ),
        .executableTarget(
            name: "CrateDigr",
            dependencies: ["CLibAubio", "CLibKeyFinder", "CLibRubberband"],
            path: "CrateDigr",
            resources: [
                .copy("Resources/Assets.xcassets"),
                .copy("Resources/Binaries")
            ],
            linkerSettings: [
                .unsafeFlags(["-L", "CLibAubio/lib", "-L", "CLibKeyFinder/lib", "-L", "CLibRubberband/lib", "-lfftw3", "-lkeyfinder", "-lrubberband", "-lc++"]),
                .linkedFramework("Accelerate"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit")
            ]
        )
    ]
)
