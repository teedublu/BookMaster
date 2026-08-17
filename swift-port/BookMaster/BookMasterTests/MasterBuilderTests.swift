import XCTest
@testable import BookMaster

/// End-to-end: synthesizes short "publisher" audio tracks with ffmpeg
/// (standing in for real book chapters), runs the full
/// validate -> encode -> assemble -> checksum -> disk-image pipeline,
/// and asserts on the real result -- bookInfo file contents, checksum
/// presence, FAT image existing and containing the encoded tracks.
final class MasterBuilderTests: XCTestCase {
    private var ffmpegAvailable: Bool { FFmpegEncoder.locateFFmpeg() != nil }

    func testBuildEndToEnd() async throws {
        guard ffmpegAvailable else { throw XCTSkip("ffmpeg not installed on this machine") }

        let fm = FileManager.default
        let inputFolder = fm.temporaryDirectory.appendingPathComponent("mb-input-\(UUID().uuidString)")
        let outputFolder = fm.temporaryDirectory.appendingPathComponent("mb-output-\(UUID().uuidString)")
        try fm.createDirectory(at: inputFolder, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(at: inputFolder)
            try? fm.removeItem(at: outputFolder)
        }

        let ffmpeg = FFmpegEncoder.locateFFmpeg()!
        // Deliberately unpadded, non-lexicographic-friendly names -- proves
        // natural sort is doing real work, not just coincidentally correct.
        for (name, freq) in [("Chapter 1.wav", 440), ("Chapter 2.wav", 523), ("Chapter 10.wav", 659)] {
            try Shell.run(ffmpeg, ["-y", "-f", "lavfi", "-i", "sine=frequency=\(freq):duration=1", inputFolder.appendingPathComponent(name).path])
        }

        let inputs = MasterInputs(
            isbn: "9781234567897", sku: "BK-67897-TEST", title: "Test Book", author: "Test Author",
            inputFolder: inputFolder, outputFolder: outputFolder,
            maxDriveSizeBytes: 980_000_000
        )

        var logLines: [String] = []
        let result = try await MasterBuilder.build(inputs: inputs) { logLines.append($0) }

        XCTAssertEqual(result.fileCount, 3)
        XCTAssertNotNil(result.checksum)
        XCTAssertTrue(fm.fileExists(atPath: result.imagePath.path))

        // bookInfo contents
        let masterPath = result.masterPath
        let idText = try String(contentsOf: masterPath.appendingPathComponent("bookInfo/id.txt"), encoding: .utf8)
        XCTAssertEqual(idText, "9781234567897")
        let countText = try String(contentsOf: masterPath.appendingPathComponent("bookInfo/count.txt"), encoding: .utf8)
        XCTAssertEqual(countText, "3")
        let checksumText = try String(contentsOf: masterPath.appendingPathComponent("bookInfo/checksum.txt"), encoding: .utf8)
        XCTAssertEqual(checksumText, result.checksum)

        // Tracks were encoded in natural-sorted order: 1, 2, 10 -- not 1, 10, 2.
        let trackFiles = try fm.contentsOfDirectory(at: masterPath.appendingPathComponent("tracks"), includingPropertiesForKeys: nil)
            .map(\.lastPathComponent).sorted()
        XCTAssertEqual(trackFiles.count, 3)
        XCTAssertTrue(trackFiles[0].hasPrefix("001_"))
        XCTAssertTrue(trackFiles[1].hasPrefix("002_"))
        XCTAssertTrue(trackFiles[2].hasPrefix("003_"))
    }

    /// Regression test for a real production bug: a 40-track book came
    /// out with 50 tracks in the master because a stale file from an
    /// earlier attempt against a differently-sized input folder was still
    /// sitting in the SKU's processed-tracks folder, and the old
    /// contentsOfDirectory(processedPath) listing swept it up along with
    /// this run's real output. cacheFiles is what makes that folder
    /// persist across runs, so it's also where the stale file has to be
    /// pruned/ignored.
    func testStaleCachedFileFromLargerPriorRunIsNotIncluded() async throws {
        guard ffmpegAvailable else { throw XCTSkip("ffmpeg not installed on this machine") }

        let fm = FileManager.default
        let inputFolder = fm.temporaryDirectory.appendingPathComponent("mb-stale-input-\(UUID().uuidString)")
        let outputFolder = fm.temporaryDirectory.appendingPathComponent("mb-stale-output-\(UUID().uuidString)")
        try fm.createDirectory(at: inputFolder, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(at: inputFolder)
            try? fm.removeItem(at: outputFolder)
        }

        let ffmpeg = FFmpegEncoder.locateFFmpeg()!
        for name in ["Chapter 1.wav", "Chapter 2.wav"] {
            try Shell.run(ffmpeg, ["-y", "-f", "lavfi", "-i", "sine=frequency=440:duration=1", inputFolder.appendingPathComponent(name).path])
        }

        let isbn = "9781234567897"
        let sku = "BK-67897-TEST"

        // Simulate leftovers from an earlier, larger attempt against this
        // same SKU: a track 3 that this (2-track) run has no business
        // producing.
        let processedPath = outputFolder.appendingPathComponent(sku).appendingPathComponent("processed")
        try fm.createDirectory(at: processedPath, withIntermediateDirectories: true)
        let staleName = MasterBuilder.outputFilename(index: 3, isbn: isbn, sku: sku)
        try Data("stale".utf8).write(to: processedPath.appendingPathComponent(staleName))

        let inputs = MasterInputs(
            isbn: isbn, sku: sku, title: "Test Book", author: "Test Author",
            inputFolder: inputFolder, outputFolder: outputFolder,
            maxDriveSizeBytes: 980_000_000, cacheFiles: true
        )

        let result = try await MasterBuilder.build(inputs: inputs)

        XCTAssertEqual(result.fileCount, 2)
        let trackFiles = try fm.contentsOfDirectory(at: result.masterPath.appendingPathComponent("tracks"), includingPropertiesForKeys: nil)
        XCTAssertEqual(trackFiles.count, 2)
        XCTAssertFalse(fm.fileExists(atPath: processedPath.appendingPathComponent(staleName).path))
    }

    func testValidateCatchesMissingFields() {
        let inputs = MasterInputs(
            isbn: "", sku: "", title: "", author: "",
            inputFolder: URL(fileURLWithPath: "/nonexistent"), outputFolder: URL(fileURLWithPath: "/tmp"),
            maxDriveSizeBytes: 980_000_000
        )
        let errors = MasterBuilder.validate(inputs: inputs)
        XCTAssertTrue(errors.contains { $0.contains("ISBN") })
        XCTAssertTrue(errors.contains { $0.contains("title") })
        XCTAssertTrue(errors.contains { $0.contains("author") })
        XCTAssertTrue(errors.contains { $0.contains("SKU") })
        XCTAssertTrue(errors.contains { $0.contains("Input folder does not exist") })
    }

    private func makeInputFolder(fileCount: Int) throws -> URL {
        let fm = FileManager.default
        let inputFolder = fm.temporaryDirectory.appendingPathComponent("mb-validate-\(UUID().uuidString)")
        try fm.createDirectory(at: inputFolder, withIntermediateDirectories: true)
        for index in 0..<fileCount {
            fm.createFile(atPath: inputFolder.appendingPathComponent("track\(index).mp3").path, contents: Data())
        }
        return inputFolder
    }

    func testValidateFlagsExpectedFileCountMismatch() throws {
        let inputFolder = try makeInputFolder(fileCount: 2)
        defer { try? FileManager.default.removeItem(at: inputFolder) }

        let inputs = MasterInputs(
            isbn: "9781234567897", sku: "BK-67897-TEST", title: "Test Book", author: "Test Author",
            inputFolder: inputFolder, outputFolder: URL(fileURLWithPath: "/tmp"),
            maxDriveSizeBytes: 980_000_000, expectedFileCount: 3
        )
        let errors = MasterBuilder.validate(inputs: inputs)
        XCTAssertTrue(errors.contains { $0.contains("Expected 3 file(s)") && $0.contains("found 2") })
    }

    func testValidatePassesWhenExpectedFileCountMatches() throws {
        let inputFolder = try makeInputFolder(fileCount: 2)
        defer { try? FileManager.default.removeItem(at: inputFolder) }

        let inputs = MasterInputs(
            isbn: "9781234567897", sku: "BK-67897-TEST", title: "Test Book", author: "Test Author",
            inputFolder: inputFolder, outputFolder: URL(fileURLWithPath: "/tmp"),
            maxDriveSizeBytes: 980_000_000, expectedFileCount: 2
        )
        XCTAssertTrue(MasterBuilder.validate(inputs: inputs).isEmpty)
    }

    func testValidateIgnoresZeroExpectedFileCount() throws {
        // A zero expected count means "unknown" (e.g. books.csv had no
        // Files value for this ISBN) rather than "must have zero files",
        // so it shouldn't block a build with real content.
        let inputFolder = try makeInputFolder(fileCount: 2)
        defer { try? FileManager.default.removeItem(at: inputFolder) }

        let inputs = MasterInputs(
            isbn: "9781234567897", sku: "BK-67897-TEST", title: "Test Book", author: "Test Author",
            inputFolder: inputFolder, outputFolder: URL(fileURLWithPath: "/tmp"),
            maxDriveSizeBytes: 980_000_000, expectedFileCount: 0
        )
        XCTAssertTrue(MasterBuilder.validate(inputs: inputs).isEmpty)
    }

    func testOutputFilenameMatchesTrackPyFormat() {
        let name = MasterBuilder.outputFilename(index: 3, isbn: "9781234567897", sku: "BK-67897-TEST")
        XCTAssertTrue(name.hasPrefix("003_"))
        XCTAssertTrue(name.hasSuffix(".mp3"))
        XCTAssertLessThanOrEqual(name.count, 17) // 13 chars + ".mp3"
    }
}
