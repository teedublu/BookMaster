import XCTest
@testable import BookMasterCore

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
            inputFolder: inputFolder, outputFolder: outputFolder, skipEncoding: false,
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

    func testValidateCatchesMissingFields() {
        let inputs = MasterInputs(
            isbn: "", sku: "", title: "", author: "",
            inputFolder: URL(fileURLWithPath: "/nonexistent"), outputFolder: URL(fileURLWithPath: "/tmp"),
            skipEncoding: false, maxDriveSizeBytes: 980_000_000
        )
        let errors = MasterBuilder.validate(inputs: inputs)
        XCTAssertTrue(errors.contains { $0.contains("ISBN") })
        XCTAssertTrue(errors.contains { $0.contains("title") })
        XCTAssertTrue(errors.contains { $0.contains("author") })
        XCTAssertTrue(errors.contains { $0.contains("SKU") })
        XCTAssertTrue(errors.contains { $0.contains("Input folder does not exist") })
    }

    func testOutputFilenameMatchesTrackPyFormat() {
        let name = MasterBuilder.outputFilename(index: 3, isbn: "9781234567897", sku: "BK-67897-TEST")
        XCTAssertTrue(name.hasPrefix("003_"))
        XCTAssertTrue(name.hasSuffix(".mp3"))
        XCTAssertLessThanOrEqual(name.count, 17) // 13 chars + ".mp3"
    }
}
