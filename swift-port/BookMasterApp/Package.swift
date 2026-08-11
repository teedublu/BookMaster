// swift-tools-version:5.10
import PackageDescription

// This package now holds only the app's non-UI logic (settings/config
// models, DiskArbitration monitor, disk image authoring, encoding,
// etc.), unit-tested independently of any UI. The app itself lives in
// ../BookMaster/BookMaster.xcodeproj, a native Xcode app target that
// depends on this package -- see that project's README for why: a real
// Info.plist, asset catalog, and Signing & Capabilities UI need an
// actual Xcode app target, which SwiftPM executable products don't
// provide.
let package = Package(
    name: "BookMasterCore",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "BookMasterCore", targets: ["BookMasterCore"])
    ],
    targets: [
        .target(
            name: "BookMasterCore",
            path: "Sources/BookMasterCore",
            resources: [
                .copy("Resources/config.json"),
                .copy("Resources/books.csv"),
            ]
        ),
        .testTarget(
            name: "BookMasterCoreTests",
            dependencies: ["BookMasterCore"],
            path: "Tests/BookMasterCoreTests"
        ),
    ]
)
