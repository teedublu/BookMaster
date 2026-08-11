// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "BookMasterApp",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        // Non-UI logic: settings/config models, DiskArbitration monitor,
        // disk image authoring, etc. Split out from the app executable
        // so it's unit-testable (Phase 8) and independently exercisable
        // without a running UI (used that way for Phase 3's validation).
        .target(
            name: "BookMasterCore",
            path: "Sources/BookMasterCore",
            resources: [
                .copy("Resources/config.json"),
                .copy("Resources/books.csv"),
            ]
        ),
        .executableTarget(
            name: "BookMasterApp",
            dependencies: ["BookMasterCore"],
            path: "Sources/BookMasterApp"
        ),
        .testTarget(
            name: "BookMasterCoreTests",
            dependencies: ["BookMasterCore"],
            path: "Tests/BookMasterCoreTests"
        ),
    ]
)
