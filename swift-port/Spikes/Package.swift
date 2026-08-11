// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Spikes",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        // Spike 1 — DiskArbitration-based USB mount/unmount detection,
        // replacing the psutil-polling USBHub.
        .executableTarget(
            name: "DiskArbitrationSpike",
            path: "Sources/DiskArbitrationSpike"
        ),

        // Spike 2 — raw device write path prototype (tested against a
        // regular file, not a live device — see README).
        .executableTarget(
            name: "RawWriteSpike",
            path: "Sources/RawWriteSpike"
        ),

        // Spike 3 — hdiutil-based FAT image authoring, replacing
        // mkfs.vfat + mtools.
        .executableTarget(
            name: "FATImageSpike",
            path: "Sources/FATImageSpike"
        ),

        // Spike 4 — Vision/AVFoundation barcode scanning design sketch,
        // replacing opencv + pyzbar. Not runnable headlessly (needs a
        // camera-permission-capable app bundle) — see README.
        .executableTarget(
            name: "BarcodeSpike",
            path: "Sources/BarcodeSpike"
        ),
    ]
)
