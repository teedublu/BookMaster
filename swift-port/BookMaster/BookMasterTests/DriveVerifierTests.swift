import XCTest
@testable import BookMaster

final class DriveVerifierTests: XCTestCase {

    // MARK: - SKU / ISBN parsing (pure functions)

    func testNormalizeVolumeSKUAcceptsHyphenatedForm() {
        XCTAssertEqual(DriveVerifier.normalizeVolumeSKU("BK-74107-CLAE"), "BK-74107-CLAE")
    }

    func testNormalizeVolumeSKUAcceptsCompactForm() {
        // Finder/FAT volume names sometimes lose hyphens or get case-folded.
        XCTAssertEqual(DriveVerifier.normalizeVolumeSKU("bk74107clae"), "BK-74107-CLAE")
    }

    func testNormalizeVolumeSKURejectsGarbage() {
        XCTAssertNil(DriveVerifier.normalizeVolumeSKU("UNTITLED"))
        XCTAssertNil(DriveVerifier.normalizeVolumeSKU(""))
    }

    func testParseISBNFromKeyValueLine() {
        let text = "Title: Some Book\nISBN: 9781234567897\nAuthor: Someone\n"
        XCTAssertEqual(DriveVerifier.parseISBN(fromIdFileText: text), "9781234567897")
    }

    func testParseISBNFallsBackToBareRegexMatch() {
        // No "ISBN:" key, just a bare 13-digit string starting 978/979.
        let text = "9781234567897\n"
        XCTAssertEqual(DriveVerifier.parseISBN(fromIdFileText: text), "9781234567897")
    }

    func testParseISBNReturnsNilForEmptyFile() {
        XCTAssertNil(DriveVerifier.parseISBN(fromIdFileText: ""))
    }

    // MARK: - Artifact cleanup

    func testRemovesUnexpectedArtifactsButKeepsRealContent() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("verify-artifacts-\(UUID().uuidString)")
        try fm.createDirectory(at: dir.appendingPathComponent("tracks"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent(".fseventsd"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        try "real".write(to: dir.appendingPathComponent("tracks/001.mp3"), atomically: true, encoding: .utf8)
        try "junk".write(to: dir.appendingPathComponent(".DS_Store"), atomically: true, encoding: .utf8)
        try "junk".write(to: dir.appendingPathComponent("._resourcefork"), atomically: true, encoding: .utf8)

        let (found, removed, samples) = DriveVerifier.removeUnexpectedEntries(at: dir)
        XCTAssertGreaterThanOrEqual(found, 3)
        XCTAssertEqual(removed, found)
        XCTAssertFalse(samples.isEmpty)

        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent("tracks/001.mp3").path), "real content must survive cleanup")
        XCTAssertFalse(fm.fileExists(atPath: dir.appendingPathComponent(".DS_Store").path))
        XCTAssertFalse(fm.fileExists(atPath: dir.appendingPathComponent(".fseventsd").path))
        // The specific regression this guards: FileManager's own
        // directory-listing APIs (contentsOfDirectory, enumerator(at:))
        // never list "._*" files at all, confirmed even on a real
        // mounted FAT16 volume -- removeUnexpectedEntries must use
        // RawDirectoryLister, not FileManager, or this silently never
        // gets found in the first place.
        XCTAssertFalse(fm.fileExists(atPath: dir.appendingPathComponent("._resourcefork").path), "\"._*\" AppleDouble files must be found and removed too, not just files FileManager's own APIs happen to list")
    }

    // MARK: - Full verify() against a synthetic mounted-drive folder

    func testVerifySucceedsAgainstWellFormedMasterFolder() async throws {
        guard FFmpegEncoder.locateFFmpeg() != nil else { throw XCTSkip("ffmpeg not installed") }

        let fm = FileManager.default
        // Volume name doubles as the mount point's last path component,
        // exactly like a real mounted drive's Finder-visible name.
        let mountPoint = fm.temporaryDirectory.appendingPathComponent("BK-99999-VRFY-\(UUID().uuidString.prefix(4))")
        try fm.createDirectory(at: mountPoint.appendingPathComponent("bookInfo"), withIntermediateDirectories: true)
        try fm.createDirectory(at: mountPoint.appendingPathComponent("tracks"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: mountPoint) }

        try "9781234567897".write(to: mountPoint.appendingPathComponent("bookInfo/id.txt"), atomically: true, encoding: .utf8)
        try Shell.run(FFmpegEncoder.locateFFmpeg()!, [
            "-y", "-f", "lavfi", "-i", "sine=frequency=440:duration=2", "-ab", "96k",
            mountPoint.appendingPathComponent("tracks/001.mp3").path,
        ])

        let result = try await DriveVerifier.verify(
            mountPoint: mountPoint, rawDevicePath: nil, skipSpeedTest: true, deepAudioInspect: true
        )

        XCTAssertTrue(result.isValid)
        XCTAssertTrue(result.detectedSKU?.hasPrefix("BK-99999-VRFY") ?? false)
        XCTAssertEqual(result.detectedISBN, "9781234567897")
        XCTAssertEqual(result.trackCount, 1)
        XCTAssertNotNil(result.expectedDurationSeconds)
        // tracksSizeMib is what the Verify Master UI's "Tracks Size" row
        // shows next to the catalog/inferred duration comparison. Not
        // asserting > 0 here: this fixture's 2s/96kbps clip is ~24KB,
        // which legitimately rounds to 0.0 at 1dp -- the field being
        // populated (not nil) is what matters.
        XCTAssertNotNil(result.tracksSizeMib)
    }

    func testVerifyThrowsWhenIdentitySignalsAreMissing() async throws {
        let fm = FileManager.default
        // No recognizable SKU in the name, no bookInfo/id.txt at all.
        let mountPoint = fm.temporaryDirectory.appendingPathComponent("UNTITLED-\(UUID().uuidString)")
        try fm.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: mountPoint) }

        do {
            _ = try await DriveVerifier.verify(mountPoint: mountPoint, rawDevicePath: nil, skipSpeedTest: true, deepAudioInspect: false)
            XCTFail("expected verification to fail for a drive with no identifiable SKU/ISBN")
        } catch let error as DriveVerifierError {
            guard case .verificationFailed(let errors) = error else {
                XCTFail("expected verificationFailed, got \(error)")
                return
            }
            XCTAssertTrue(errors.contains { $0.contains("SKU") })
            XCTAssertTrue(errors.contains { $0.contains("ISBN") })
        }
    }
}
