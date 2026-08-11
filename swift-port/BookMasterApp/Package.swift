// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "BookMasterApp",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "BookMasterApp",
            path: "Sources/BookMasterApp",
            resources: [
                .copy("Resources/config.json")
            ]
        )
    ]
)
