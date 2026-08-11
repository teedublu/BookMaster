import XCTest
@testable import BookMaster

final class MBRImageBuilderTests: XCTestCase {

    // MARK: - Size bucketing (pure function, matches voxmaster's Python exactly)

    func testDestinationImageBytesFloorsAt128MiBEvenForTinyContent() {
        let result = MBRImageBuilder.destinationImageBytes(usedBytes: 1_000, minSizeMib: 128)
        XCTAssertEqual(result, 128 * 1024 * 1024)
    }

    func testDestinationImageBytesPicksNextBucketWhenContentExceedsOne() {
        // 200 MiB used + 32 MiB margin > 128 MiB bucket -> should land in 256 MiB bucket.
        let used = Int64(200) * 1024 * 1024
        let result = MBRImageBuilder.destinationImageBytes(usedBytes: used, minSizeMib: 128)
        XCTAssertEqual(result, 256 * 1024 * 1024)
    }

    func testDestinationImageBytesUsesDecimalGBAboveFixedBuckets() {
        // Well above the largest fixed bucket (975 MB) -> decimal GB minus 5MB headroom.
        let used = Int64(3) * 1_000_000_000
        let result = MBRImageBuilder.destinationImageBytes(usedBytes: used, minSizeMib: 128)
        XCTAssertLessThan(result, 4_000_000_000)
        XCTAssertGreaterThan(result, 3_000_000_000)
        // Never lands exactly on a decimal GB boundary.
        XCTAssertNotEqual(result % 1_000_000_000, 0)
    }

    func testSafeVolumeLabelStripsForbiddenCharsAndCaps11() {
        XCTAssertEqual(MBRImageBuilder.safeVolumeLabel("BK-12345-TEST", fallback: "X"), "BK-12345-TE")
        XCTAssertEqual(MBRImageBuilder.safeVolumeLabel(nil, fallback: "FALLBACKLABEL"), "FALLBACKLAB")
    }

    // MARK: - Real end-to-end image build + inspection

    func testBuildMBRImageEndToEnd() throws {
        let fm = FileManager.default
        let sourceDir = fm.temporaryDirectory.appendingPathComponent("mbr-test-source-\(UUID().uuidString)")
        let outputDir = fm.temporaryDirectory.appendingPathComponent("mbr-test-output-\(UUID().uuidString)")
        try fm.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(at: sourceDir)
            try? fm.removeItem(at: outputDir)
        }

        try fm.createDirectory(at: sourceDir.appendingPathComponent("tracks"), withIntermediateDirectories: true)
        try "chapter one".write(to: sourceDir.appendingPathComponent("tracks/001.mp3"), atomically: true, encoding: .utf8)
        try "book-id".write(to: sourceDir.appendingPathComponent("id.txt"), atomically: true, encoding: .utf8)
        try "junk".write(to: sourceDir.appendingPathComponent(".DS_Store"), atomically: true, encoding: .utf8)

        var logLines: [String] = []
        let result = try MBRImageBuilder.buildImage(
            fromSourceFolder: sourceDir,
            volumeLabel: "BK-12345-TEST",
            outputPath: outputDir,
            log: { logLines.append($0) }
        )

        XCTAssertTrue(fm.fileExists(atPath: result.imagePath.path))
        XCTAssertGreaterThanOrEqual(result.sizeBytes, 128 * 1024 * 1024)

        // Real byte-level validation, not just "hdiutil says it worked".
        let layout = try ImageLayoutInspector.inspect(result.imagePath)
        XCTAssertEqual(layout.kind, .mbrFat)
        XCTAssertEqual(layout.fatVariant, "FAT32")
        XCTAssertNotNil(layout.partitionStartLBA)
        XCTAssertGreaterThan(layout.partitionStartLBA ?? 0, 0, "MBR partition must not start at sector 0")

        // Content round-trip: attach read-only and check the files are really there.
        let attachOut = try Shell.run("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", result.imagePath.path])
        guard let device = Shell.devicePath(fromAttachOutput: attachOut),
              let mountPoint = Shell.mountPath(fromAttachOutput: attachOut) else {
            XCTFail("could not parse hdiutil attach output: \(attachOut)")
            return
        }
        defer { try? Shell.run("/usr/bin/hdiutil", ["detach", device]) }

        let mountURL = URL(fileURLWithPath: mountPoint)
        let idContents = try String(contentsOf: mountURL.appendingPathComponent("id.txt"), encoding: .utf8)
        XCTAssertEqual(idContents, "book-id")
        XCTAssertFalse(fm.fileExists(atPath: mountURL.appendingPathComponent(".DS_Store").path))
    }

    func testBuildMBRImageThrowsOnMissingSource() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID().uuidString)")
        XCTAssertThrowsError(try MBRImageBuilder.buildImage(fromSourceFolder: missing, volumeLabel: "X", outputPath: FileManager.default.temporaryDirectory))
    }

    // MARK: - Layout inspector correctly distinguishes superfloppy from MBR

    func testLayoutInspectorIdentifiesSuperfloppyImage() throws {
        let fm = FileManager.default
        let sourceDir = fm.temporaryDirectory.appendingPathComponent("layout-src-\(UUID().uuidString)")
        let outputDir = fm.temporaryDirectory.appendingPathComponent("layout-out-\(UUID().uuidString)")
        try fm.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(at: sourceDir)
            try? fm.removeItem(at: outputDir)
        }
        try "x".write(to: sourceDir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let result = try DiskImageBuilder.buildImage(fromSourceFolder: sourceDir, volumeLabel: "SFTEST", outputPath: outputDir)
        let layout = try ImageLayoutInspector.inspect(result.imagePath)
        XCTAssertEqual(layout.kind, .superfloppyFat)
        XCTAssertNil(layout.partitionStartLBA, "a superfloppy image has no partition table")
    }
}
