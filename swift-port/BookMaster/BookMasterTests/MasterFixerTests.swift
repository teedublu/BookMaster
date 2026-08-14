import XCTest
@testable import BookMaster

final class MasterFixerTests: XCTestCase {

    // MARK: - DriveVerifier.removeUnexpectedEntries(dryRun:)

    func testRemoveUnexpectedEntriesDryRunReportsButDoesNotDelete() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("dryrun-artifacts-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        try "junk".write(to: dir.appendingPathComponent(".DS_Store"), atomically: true, encoding: .utf8)

        let (found, removed, _) = DriveVerifier.removeUnexpectedEntries(at: dir, dryRun: true)
        XCTAssertEqual(found, 1)
        XCTAssertEqual(removed, 0, "dry run must not report anything as removed")
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent(".DS_Store").path), "dry run must not actually delete the file")
    }

    // MARK: - MasterFixer.removeArtifacts

    func testRemoveArtifactsActuallyDeletes() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("fix-artifacts-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        try "junk".write(to: dir.appendingPathComponent(".DS_Store"), atomically: true, encoding: .utf8)

        let result = MasterFixer.removeArtifacts(at: dir)
        XCTAssertEqual(result.found, 1)
        XCTAssertEqual(result.removed, 1)
        XCTAssertFalse(fm.fileExists(atPath: dir.appendingPathComponent(".DS_Store").path))
    }

    // MARK: - MasterFixer.cleanID3Tags

    func testCleanID3TagsStripsOnlyFlaggedFiles() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("fix-id3-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        // Flagged: an unexpected frame ffmpeg-style encoder tag.
        var tagged = Data([0x49, 0x44, 0x33, 3, 0, 0]) // "ID3", v2.3
        var frame = Data("TSSE".utf8)
        let body = Data([3]) + Data("Lavf60.16.100".utf8)
        frame.append(Data([0, 0, 0, UInt8(body.count)])) // big-endian size
        frame.append(Data([0, 0])) // flags
        frame.append(body)
        tagged.append(Data([
            UInt8((frame.count >> 21) & 0x7F), UInt8((frame.count >> 14) & 0x7F),
            UInt8((frame.count >> 7) & 0x7F), UInt8(frame.count & 0x7F),
        ]))
        tagged.append(frame)
        tagged.append(Data(repeating: 0xAB, count: 50)) // stand-in "audio" payload
        try tagged.write(to: dir.appendingPathComponent("001.mp3"))

        // Not flagged: no ID3 tag at all.
        try Data(repeating: 0xCD, count: 50).write(to: dir.appendingPathComponent("002.mp3"))

        let result = MasterFixer.cleanID3Tags(tracksPath: dir, isbn: nil)
        XCTAssertEqual(result.flagged, 1)
        XCTAssertEqual(result.cleaned, 1)
        XCTAssertEqual(result.samples, ["001.mp3"])

        XCTAssertFalse(ID3Tag.hasID3v2Header(at: dir.appendingPathComponent("001.mp3")))
        // The payload after the tag must survive the strip untouched.
        let remaining = try Data(contentsOf: dir.appendingPathComponent("001.mp3"))
        XCTAssertEqual(remaining, Data(repeating: 0xAB, count: 50))

        // The untouched file's own bytes must be untouched too.
        let untouched = try Data(contentsOf: dir.appendingPathComponent("002.mp3"))
        XCTAssertEqual(untouched, Data(repeating: 0xCD, count: 50))

        let issuesAfter = DriveVerifier.scanForID3TagIssues(tracksPath: dir, isbn: nil)
        XCTAssertTrue(issuesAfter.isEmpty, "cleaned file should no longer be flagged")
    }

    // MARK: - ID3Tag.stripTags

    func testStripTagsRemovesV2HeaderAndV1TrailerKeepingPayload() throws {
        let fm = FileManager.default
        let file = fm.temporaryDirectory.appendingPathComponent("strip-both-\(UUID().uuidString).mp3")
        defer { try? fm.removeItem(at: file) }

        let payload = Data(repeating: 0x55, count: 100)
        var data = Data([0x49, 0x44, 0x33, 3, 0, 0, 0, 0, 0, 0]) // header only, zero-size body
        data.append(payload)
        data.append(Data("TAG".utf8))
        data.append(Data(repeating: 0, count: 125))
        try data.write(to: file)

        XCTAssertTrue(ID3Tag.stripTags(at: file))
        let result = try Data(contentsOf: file)
        XCTAssertEqual(result, payload)
    }

    func testStripTagsIsNoOpWhenNoTagsPresent() throws {
        let fm = FileManager.default
        let file = fm.temporaryDirectory.appendingPathComponent("strip-noop-\(UUID().uuidString).mp3")
        defer { try? fm.removeItem(at: file) }

        let payload = Data(repeating: 0x77, count: 50)
        try payload.write(to: file)

        XCTAssertTrue(ID3Tag.stripTags(at: file))
        let result = try Data(contentsOf: file)
        XCTAssertEqual(result, payload)
    }
}
