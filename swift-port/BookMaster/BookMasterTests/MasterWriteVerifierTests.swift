import XCTest
@testable import BookMaster

final class MasterWriteVerifierTests: XCTestCase {
    private var scratchDirectories: [URL] = []

    override func tearDown() {
        for directory in scratchDirectories {
            // Built images are locked with chflags uchg (DiskImageBuilder.lockReadOnly), which blocks removal.
            try? Shell.run("/usr/bin/chflags", ["-R", "nouchg", directory.path])
            try? FileManager.default.removeItem(at: directory)
        }
        scratchDirectories = []
        super.tearDown()
    }

    private func makeScratchDirectory(_ label: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        scratchDirectories.append(directory)
        return directory
    }

    private func write(_ data: Data, to root: URL, _ relativePath: String) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private func writeMasterContent(in root: URL) throws {
        try write(Data("9781917979078".utf8), to: root, "bookInfo/id.txt")
        try write(Data("2".utf8), to: root, "bookInfo/count.txt")
        try write(Data(repeating: 0xAB, count: 64 * 1024), to: root, "tracks/001_79078RRPL.mp3")
        try write(Data(repeating: 0xCD, count: 4 * 1024 * 1024), to: root, "tracks/002_79078RRPL.mp3")
        try write(Data(), to: root, ".metadata_never_index")
    }

    func testMatchingBlockVerifiesAndMacOSArtifactsAreIgnored() throws {
        let image = try makeScratchDirectory("writeverify-image")
        let block = try makeScratchDirectory("writeverify-block")
        try writeMasterContent(in: image)
        try writeMasterContent(in: block)
        try write(Data("cruft".utf8), to: block, ".fseventsd/fseventsd-uuid")
        try write(Data("cruft".utf8), to: block, "tracks/._002_79078RRPL.mp3")

        let result = MasterWriteVerifier.compare(expectedRoot: image, actualRoot: block)

        XCTAssertEqual(result.problems, [])
        XCTAssertTrue(result.isVerified)
        XCTAssertEqual(result.fileCount, 5)
        let expectedByteCount: Int64 = 13 + 1 + 64 * 1024 + 4 * 1024 * 1024
        XCTAssertEqual(result.byteCount, expectedByteCount)
    }

    func testReportsDamagedMissingTruncatedAndExtraFiles() throws {
        let image = try makeScratchDirectory("writeverify-image")
        let block = try makeScratchDirectory("writeverify-block")
        try writeMasterContent(in: image)
        try writeMasterContent(in: block)

        // The field failure's shape: right file size, a region mid-track that doesn't hold the written bytes.
        var damaged = Data(repeating: 0xCD, count: 4 * 1024 * 1024)
        damaged.replaceSubrange(3_002_402..<3_133_746, with: Data(repeating: 0x00, count: 131_344))
        try write(damaged, to: block, "tracks/002_79078RRPL.mp3")
        try write(Data(repeating: 0xAB, count: 60 * 1024), to: block, "tracks/001_79078RRPL.mp3")
        try FileManager.default.removeItem(at: block.appendingPathComponent("bookInfo/count.txt"))
        try write(Data("stray".utf8), to: block, "tracks/003_79078RRPL.mp3")

        // A chunk boundary at 3,050,000 falls inside the damaged region.
        let result = MasterWriteVerifier.compare(expectedRoot: image, actualRoot: block, chunkSize: 3_050_000)

        XCTAssertFalse(result.isVerified)
        XCTAssertEqual(result.problems, [
            "bookInfo/count.txt: missing from the block",
            "tracks/001_79078RRPL.mp3: 61440 bytes on the block but 65536 in the image",
            "tracks/002_79078RRPL.mp3: 131344 bytes differ from the image, starting at byte 3002402",
            "tracks/003_79078RRPL.mp3: on the block but not in the image",
        ])
    }

    func testVerifyMountsTheImageAndCatchesATrackDamagedOnAMountedBlock() throws {
        let source = try makeScratchDirectory("writeverify-source")
        let output = try makeScratchDirectory("writeverify-output")
        try writeMasterContent(in: source)
        let image = try DiskImageBuilder.buildImage(fromSourceFolder: source, volumeLabel: "BK-79078-RRPL", outputPath: output).imagePath

        // Stand-in for the written block: a writable copy of the image, mounted under the same volume label.
        let blockImage = output.appendingPathComponent("block.img")
        try FileManager.default.copyItem(at: image, to: blockImage)
        try Shell.run("/usr/bin/chflags", ["nouchg", blockImage.path])
        try Shell.run("/bin/chmod", ["644", blockImage.path])
        let attachOutput = try Shell.run("/usr/bin/hdiutil", [
            "attach", "-imagekey", "diskimage-class=CRawDiskImage", "-nobrowse", blockImage.path,
        ])
        let device = try XCTUnwrap(Shell.devicePath(fromAttachOutput: attachOutput))
        defer { try? Shell.run("/usr/bin/hdiutil", ["detach", device]) }
        let block = URL(fileURLWithPath: try XCTUnwrap(Shell.mountPath(fromAttachOutput: attachOutput)))

        let clean = try MasterWriteVerifier.verify(imagePath: image, writtenVolume: block)
        XCTAssertEqual(clean.problems, [])
        XCTAssertEqual(clean.fileCount, 5)

        let track = try FileHandle(forUpdating: block.appendingPathComponent("tracks/002_79078RRPL.mp3"))
        try track.seek(toOffset: 1_000_000)
        try track.write(contentsOf: Data(repeating: 0x00, count: 131_344))
        try track.close()

        let damaged = try MasterWriteVerifier.verify(imagePath: image, writtenVolume: block)
        XCTAssertEqual(damaged.problems, [
            "tracks/002_79078RRPL.mp3: 131344 bytes differ from the image, starting at byte 1000000",
        ])
    }
}
