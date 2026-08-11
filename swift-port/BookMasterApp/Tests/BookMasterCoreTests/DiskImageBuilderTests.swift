import XCTest
@testable import BookMasterCore

/// Exercises the real service (not just Phase 0's throwaway spike)
/// end-to-end: builds a FAT image from a scratch source folder, then
/// re-attaches it read-only to verify the filesystem type and file
/// contents round-tripped correctly. Only touches files under a temp
/// directory — never a real device.
final class DiskImageBuilderTests: XCTestCase {
    func testBuildImageRoundTrips() throws {
        let fm = FileManager.default
        let sourceDir = fm.temporaryDirectory.appendingPathComponent("dib-test-source-\(UUID().uuidString)")
        let outputDir = fm.temporaryDirectory.appendingPathComponent("dib-test-output-\(UUID().uuidString)")
        try fm.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(at: sourceDir)
            try? fm.removeItem(at: outputDir)
        }

        // A source tree with a nested folder, a normal file, and files
        // that should be excluded by config.json's patterns_to_remove.
        try fm.createDirectory(at: sourceDir.appendingPathComponent("tracks"), withIntermediateDirectories: true)
        try "chapter one".write(to: sourceDir.appendingPathComponent("tracks/001.mp3"), atomically: true, encoding: .utf8)
        try "book-id-contents".write(to: sourceDir.appendingPathComponent("id.txt"), atomically: true, encoding: .utf8)
        try "junk".write(to: sourceDir.appendingPathComponent(".DS_Store"), atomically: true, encoding: .utf8)
        try "junk".write(to: sourceDir.appendingPathComponent("._resourcefork"), atomically: true, encoding: .utf8)

        var logLines: [String] = []
        let result = try DiskImageBuilder.buildImage(
            fromSourceFolder: sourceDir,
            volumeLabel: "BK-12345-TEST",
            outputPath: outputDir,
            log: { logLines.append($0) }
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: result.imagePath.path))
        XCTAssertEqual(result.volumeLabel, "BK12345TEST") // hyphens stripped, uppercased, <=11 chars
        XCTAssertGreaterThanOrEqual(result.sizeBytes, 10 * 1024 * 1024) // 10MB floor

        // Re-attach read-only and verify contents + exclusions.
        let attachOut = try Shell.run("/usr/bin/hdiutil", [
            "attach", "-imagekey", "diskimage-class=CRawDiskImage", "-readonly", "-nobrowse", result.imagePath.path,
        ])
        guard let device = Shell.devicePath(fromAttachOutput: attachOut),
              let mountPoint = Shell.mountPath(fromAttachOutput: attachOut) else {
            XCTFail("could not parse hdiutil attach output: \(attachOut)")
            return
        }
        defer { try? Shell.run("/usr/bin/hdiutil", ["detach", device]) }

        let mountURL = URL(fileURLWithPath: mountPoint)
        let idContents = try String(contentsOf: mountURL.appendingPathComponent("id.txt"), encoding: .utf8)
        XCTAssertEqual(idContents, "book-id-contents")

        let trackContents = try String(contentsOf: mountURL.appendingPathComponent("tracks/001.mp3"), encoding: .utf8)
        XCTAssertEqual(trackContents, "chapter one")

        XCTAssertFalse(fm.fileExists(atPath: mountURL.appendingPathComponent(".DS_Store").path), "excluded pattern should not have been copied")
        XCTAssertFalse(fm.fileExists(atPath: mountURL.appendingPathComponent("._resourcefork").path), "excluded pattern should not have been copied")

        let diskutilInfo = try Shell.run("/usr/sbin/diskutil", ["info", device])
        XCTAssertTrue(diskutilInfo.contains("FAT"), "expected a FAT filesystem, got:\n\(diskutilInfo)")
    }

    func testBuildImageThrowsOnMissingSource() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("does-not-exist-\(UUID().uuidString)")
        XCTAssertThrowsError(try DiskImageBuilder.buildImage(
            fromSourceFolder: missing,
            volumeLabel: "TEST",
            outputPath: FileManager.default.temporaryDirectory
        ))
    }

    /// Phase 8 gap-closing: an empty source folder must still produce a
    /// valid (10MB-floor) image rather than crashing or producing a
    /// zero-byte/unformattable file -- diskimage.py's own sizing math
    /// has this floor built in (`max(..., 10)`), so an empty input
    /// shouldn't be able to violate it.
    func testBuildImageWithEmptySourceFolderHitsSizeFloor() throws {
        let fm = FileManager.default
        let sourceDir = fm.temporaryDirectory.appendingPathComponent("dib-empty-\(UUID().uuidString)")
        let outputDir = fm.temporaryDirectory.appendingPathComponent("dib-empty-out-\(UUID().uuidString)")
        try fm.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(at: sourceDir)
            try? fm.removeItem(at: outputDir)
        }

        let result = try DiskImageBuilder.buildImage(fromSourceFolder: sourceDir, volumeLabel: "EMPTY", outputPath: outputDir)
        XCTAssertEqual(result.sizeBytes, 10 * 1024 * 1024)
    }
}
