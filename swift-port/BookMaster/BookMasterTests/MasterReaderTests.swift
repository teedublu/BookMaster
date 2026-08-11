import XCTest
@testable import BookMaster

final class MasterReaderTests: XCTestCase {
    func testReadsBackWhatBuilderWrote() async throws {
        guard FFmpegEncoder.locateFFmpeg() != nil else { throw XCTSkip("ffmpeg not installed") }

        let fm = FileManager.default
        let inputFolder = fm.temporaryDirectory.appendingPathComponent("mr-input-\(UUID().uuidString)")
        let outputFolder = fm.temporaryDirectory.appendingPathComponent("mr-output-\(UUID().uuidString)")
        try fm.createDirectory(at: inputFolder, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(at: inputFolder)
            try? fm.removeItem(at: outputFolder)
        }

        try Shell.run(FFmpegEncoder.locateFFmpeg()!, ["-y", "-f", "lavfi", "-i", "sine=frequency=440:duration=1", inputFolder.appendingPathComponent("t.wav").path])

        let inputs = MasterInputs(
            isbn: "9781111111111", sku: "BK-11111-TEST", title: "T", author: "A",
            inputFolder: inputFolder, outputFolder: outputFolder, skipEncoding: false,
            maxDriveSizeBytes: 980_000_000
        )
        let result = try await MasterBuilder.build(inputs: inputs)

        let content = MasterReader.read(mountPath: result.masterPath)
        XCTAssertEqual(content.isbn, "9781111111111")
        XCTAssertEqual(content.fileCount, 1)
        XCTAssertEqual(content.checksumMatches, true)
    }

    func testReadOnEmptyDirectoryReturnsNils() {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("mr-empty-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }

        let content = MasterReader.read(mountPath: empty)
        XCTAssertNil(content.isbn)
        XCTAssertNil(content.fileCount)
        XCTAssertNil(content.checksumMatches)
    }

    /// A tampered drive: content changed after checksum.txt was written.
    func testDetectsChecksumMismatch() async throws {
        guard FFmpegEncoder.locateFFmpeg() != nil else { throw XCTSkip("ffmpeg not installed") }

        let fm = FileManager.default
        let inputFolder = fm.temporaryDirectory.appendingPathComponent("mr-input2-\(UUID().uuidString)")
        let outputFolder = fm.temporaryDirectory.appendingPathComponent("mr-output2-\(UUID().uuidString)")
        try fm.createDirectory(at: inputFolder, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(at: inputFolder)
            try? fm.removeItem(at: outputFolder)
        }
        try Shell.run(FFmpegEncoder.locateFFmpeg()!, ["-y", "-f", "lavfi", "-i", "sine=frequency=440:duration=1", inputFolder.appendingPathComponent("t.wav").path])

        let inputs = MasterInputs(
            isbn: "9782222222222", sku: "BK-22222-TEST", title: "T", author: "A",
            inputFolder: inputFolder, outputFolder: outputFolder, skipEncoding: false,
            maxDriveSizeBytes: 980_000_000
        )
        let result = try await MasterBuilder.build(inputs: inputs)

        // Tamper: overwrite id.txt after the checksum was computed.
        try Data("9789999999999".utf8).write(to: result.masterPath.appendingPathComponent("bookInfo/id.txt"))

        let content = MasterReader.read(mountPath: result.masterPath)
        XCTAssertEqual(content.checksumMatches, false)
    }
}
