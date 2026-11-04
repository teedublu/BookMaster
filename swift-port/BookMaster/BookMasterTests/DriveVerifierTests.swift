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

    // MARK: - MYO blocks (VOXBLOCK volume)

    func testGenericBlockVolumeIsRecognisedIncludingMacOSNumberedCopies() {
        // macOS mounts a second block with the same label as "VOXBLOCK 1".
        for name in ["VOXBLOCK", "voxblock", " VOXBLOCK ", "VOXBLOCK 1", "VOXBLOCK 12"] {
            XCTAssertTrue(DriveVerifier.isGenericBlockVolume(name), name)
        }
    }

    func testGenericBlockVolumeRejectsOtherNames() {
        for name in ["", "VOXBLOCKS", "MYVOXBLOCK", "VOXBLOCK1", "VOXBLOCK 1A", "BK-26657-MYOB", "UNTITLED"] {
            XCTAssertFalse(DriveVerifier.isGenericBlockVolume(name), name)
        }
    }

    func testGenericBlockVolumeNameIsTheOneMastersAreBuiltWith() {
        XCTAssertEqual(DriveVerifier.genericBlockVolumeName, "VOXBLOCK")
        XCTAssertEqual(VolumeNameChoice.voxblock.fatLabel, "VOXBLOCK")
        XCTAssertNil(VolumeNameChoice.sku.fatLabel)
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

    // MARK: - ID3Tag: raw presence detection

    func testHasID3v2HeaderTrueWhenPresent() throws {
        let fm = FileManager.default
        let file = fm.temporaryDirectory.appendingPathComponent("id3v2-\(UUID().uuidString).mp3")
        defer { try? fm.removeItem(at: file) }
        var data = Data("ID3".utf8)
        data.append(Data(repeating: 0, count: 20))
        try data.write(to: file)

        XCTAssertTrue(ID3Tag.hasID3v2Header(at: file))
    }

    func testHasID3v1TrailerTrueWhenPresent() throws {
        let fm = FileManager.default
        let file = fm.temporaryDirectory.appendingPathComponent("id3v1-\(UUID().uuidString).mp3")
        defer { try? fm.removeItem(at: file) }
        var data = Data(repeating: 0, count: 200)
        data.append(Data("TAG".utf8))
        data.append(Data(repeating: 0, count: 125))
        try data.write(to: file)

        XCTAssertTrue(ID3Tag.hasID3v1Trailer(at: file))
    }

    func testHasID3TagsFalseForUntaggedFile() throws {
        let fm = FileManager.default
        let file = fm.temporaryDirectory.appendingPathComponent("untagged-\(UUID().uuidString).mp3")
        defer { try? fm.removeItem(at: file) }
        try Data(repeating: 0xFF, count: 200).write(to: file)

        XCTAssertFalse(ID3Tag.hasID3v2Header(at: file))
        XCTAssertFalse(ID3Tag.hasID3v1Trailer(at: file))
        XCTAssertEqual(ID3Tag.readID3v2Frames(at: file), [])
    }

    // MARK: - ID3Tag: frame parsing

    func testReadID3v2FramesParsesTextAndTXXXFrames() throws {
        let fm = FileManager.default
        let file = fm.temporaryDirectory.appendingPathComponent("id3-frames-\(UUID().uuidString).mp3")
        defer { try? fm.removeItem(at: file) }
        let obfuscatedISBN = Data("9781234567897".utf8).base64EncodedString()
        let tag = buildID3v23Tag(frames: [
            id3v23Frame(id: "TALB", body: id3TextFrameBody("A Bear Called Paddington")),
            id3v23Frame(id: "TPE1", body: id3TextFrameBody("Michael Bond")),
            id3v23Frame(id: "TXXX", body: id3TXXXFrameBody(desc: "ID", value: obfuscatedISBN)),
        ])
        try tag.write(to: file)

        let frames = ID3Tag.readID3v2Frames(at: file)
        XCTAssertTrue(frames.contains(ID3Tag.Frame(id: "TALB", text: "A Bear Called Paddington")))
        XCTAssertTrue(frames.contains(ID3Tag.Frame(id: "TPE1", text: "Michael Bond")))
        XCTAssertTrue(frames.contains(ID3Tag.Frame(id: "TXXX:ID", text: obfuscatedISBN)))
    }

    func testDecodeObfuscatedISBNRoundTrips() {
        let isbn = "9781234567897"
        let obfuscated = Data(isbn.utf8).base64EncodedString()
        XCTAssertEqual(ID3Tag.decodeObfuscatedISBN(obfuscated), isbn)
    }

    // MARK: - DriveVerifier.scanForID3TagIssues
    //
    // A correctly re-tagged track (TALB/TPE1/TIT2/TXXX:ID matching the
    // drive, per Track.update_mp3_tags() in track.py) must NOT be
    // flagged -- that's the expected, normal state for a real master,
    // not a problem. Only unexpected frames or mismatched values should
    // surface as issues (see the AskUserQuestion decision this shipped
    // under: "flag unexpected tags only", not "flag any tag").

    func testScanForID3TagIssuesEmptyWhenTagsMatchCatalog() throws {
        // Real books.csv fixture row: "A Bear Called Paddington" by
        // Michael Bond, ISBN 9781739693695 -- see BooksCatalogTests for
        // the same fixture assumption.
        let isbn = "9781739693695"
        guard let book = BooksCatalog.lookup(isbn: isbn) else {
            throw XCTSkip("fixture ISBN not present in bundled books.csv")
        }
        let title = book["Title"] ?? ""
        let author = book["Author"] ?? ""

        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("id3-issues-ok-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let obfuscatedISBN = Data(isbn.utf8).base64EncodedString()
        let tag = buildID3v23Tag(frames: [
            id3v23Frame(id: "TALB", body: id3TextFrameBody(title)),
            id3v23Frame(id: "TPE1", body: id3TextFrameBody(author)),
            id3v23Frame(id: "TIT2", body: id3TextFrameBody("Track 1 from \(title)")),
            id3v23Frame(id: "TXXX", body: id3TXXXFrameBody(desc: "ID", value: obfuscatedISBN)),
        ])
        try tag.write(to: dir.appendingPathComponent("001.mp3"))

        let issues = DriveVerifier.scanForID3TagIssues(tracksPath: dir, isbn: isbn)
        XCTAssertTrue(issues.isEmpty, "expected no issues for a correctly-tagged track, got \(issues)")
    }

    func testScanForID3TagIssuesFlagsUnexpectedFrame() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("id3-issues-unexpected-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        // ffmpeg's own default encoder tag -- something this app never writes.
        let tag = buildID3v23Tag(frames: [
            id3v23Frame(id: "TSSE", body: id3TextFrameBody("Lavf60.16.100")),
        ])
        try tag.write(to: dir.appendingPathComponent("001.mp3"))

        let issues = DriveVerifier.scanForID3TagIssues(tracksPath: dir, isbn: nil)
        XCTAssertEqual(issues.count, 1)
        XCTAssertTrue(issues[0].reason.contains("TSSE"), "expected the unexpected frame's ID in the reason, got: \(issues[0].reason)")
    }

    func testScanForID3TagIssuesFlagsISBNMismatch() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("id3-issues-isbn-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let wrongISBNObfuscated = Data("0000000000000".utf8).base64EncodedString()
        let tag = buildID3v23Tag(frames: [
            id3v23Frame(id: "TXXX", body: id3TXXXFrameBody(desc: "ID", value: wrongISBNObfuscated)),
        ])
        try tag.write(to: dir.appendingPathComponent("001.mp3"))

        let issues = DriveVerifier.scanForID3TagIssues(tracksPath: dir, isbn: "9781234567897")
        XCTAssertEqual(issues.count, 1)
        XCTAssertTrue(issues[0].reason.contains("ISBN"), "expected an ISBN-mismatch reason, got: \(issues[0].reason)")
    }

    func testScanForID3TagIssuesFlagsID3v1Trailer() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("id3-issues-v1-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        var data = Data(repeating: 0, count: 200)
        data.append(Data("TAG".utf8))
        data.append(Data(repeating: 0, count: 125))
        try data.write(to: dir.appendingPathComponent("001.mp3"))

        let issues = DriveVerifier.scanForID3TagIssues(tracksPath: dir, isbn: nil)
        XCTAssertEqual(issues.count, 1)
        XCTAssertTrue(issues[0].reason.contains("ID3v1"))
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
            mountPoint: mountPoint, rawDevicePath: nil, deepAudioInspect: true
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
            _ = try await DriveVerifier.verify(mountPoint: mountPoint, rawDevicePath: nil, deepAudioInspect: false)
            XCTFail("expected verification to fail for a drive with no identifiable SKU/ISBN")
        } catch let error as DriveVerifierError {
            guard case .verificationFailed(let errors, let partialResult) = error else {
                XCTFail("expected verificationFailed, got \(error)")
                return
            }
            XCTAssertTrue(errors.contains { $0.contains("SKU") })
            XCTAssertTrue(errors.contains { $0.contains("ISBN") })
            // Every other check still ran and is still available on the
            // thrown error, not just the identity failure -- a caller
            // shouldn't have to lose track count/artifacts/ID3 findings
            // just because SKU/ISBN came back missing.
            XCTAssertFalse(partialResult.isValid)
            XCTAssertEqual(partialResult.validationErrors, errors)
        }
    }

    // MARK: - MYO blocks: identity on a VOXBLOCK volume

    /// A stand-in for a mounted block: the directory's own name is the volume name, like a real mount point.
    private func makeMountPoint(volumeName: String, idText: String?) throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("verify-volume-\(UUID().uuidString)")
        let mountPoint = root.appendingPathComponent(volumeName)
        try fm.createDirectory(at: mountPoint.appendingPathComponent("bookInfo"), withIntermediateDirectories: true)
        if let idText {
            try idText.write(to: mountPoint.appendingPathComponent("bookInfo/id.txt"), atomically: true, encoding: .utf8)
        }
        addTeardownBlock { try? fm.removeItem(at: root) }
        return mountPoint
    }

    private func makeProductionLog() throws -> ProductionLog {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("verify-db-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return ProductionLog(db: try AppDatabase(path: directory.appendingPathComponent("voxmaster.db")))
    }

    private func recordKnownMaster(_ log: ProductionLog, sku: String, isbn: String) throws {
        try log.upsertMasterCatalog(
            sku: sku, imgPath: "/tmp/\(sku).img", imageBytes: 1, imageMib1dp: 128, usedMib1dp: 1,
            imageFileCount: 1, imageTrackCount: 1, imageIsbn: isbn
        )
    }

    func testGenericVolumeSKUComesFromTheBookCatalogWhenItKnowsTheISBN() throws {
        let entry = try XCTUnwrap(BooksCatalog.shared.first { key, row in
            key.count == 13 && key.allSatisfy(\.isNumber) && DriveVerifier.normalizeVolumeSKU(row["SKU"] ?? "") != nil
        })
        let expected = try XCTUnwrap(DriveVerifier.normalizeVolumeSKU(entry.value["SKU"] ?? ""))
        let mountPoint = try makeMountPoint(volumeName: "VOXBLOCK", idText: entry.key)

        let identity = DriveVerifier.detectIdentity(mountPoint: mountPoint)

        XCTAssertTrue(identity.genericVolume)
        XCTAssertEqual(identity.isbn, entry.key)
        XCTAssertEqual(identity.sku, expected)
    }

    func testGenericVolumeSKUComesFromKnownMastersWhenTheCatalogLacksTheISBN() throws {
        let log = try makeProductionLog()
        try recordKnownMaster(log, sku: "BK-26657-MYOB", isbn: "5061050126657")
        // The second block mounted with the same label.
        let mountPoint = try makeMountPoint(volumeName: "VOXBLOCK 1", idText: "5061050126657")

        let identity = DriveVerifier.detectIdentity(mountPoint: mountPoint, productionLog: log)

        XCTAssertTrue(identity.genericVolume)
        XCTAssertEqual(identity.sku, "BK-26657-MYOB")
    }

    func testGenericVolumeSKUIsLeftBlankWhenKnownMastersDisagree() throws {
        let log = try makeProductionLog()
        try recordKnownMaster(log, sku: "BK-11111-AAAA", isbn: "5061050100099")
        try recordKnownMaster(log, sku: "BK-22222-BBBB", isbn: "5061050100099")
        let mountPoint = try makeMountPoint(volumeName: "VOXBLOCK", idText: "5061050100099")

        let identity = DriveVerifier.detectIdentity(mountPoint: mountPoint, productionLog: log)

        XCTAssertTrue(identity.genericVolume)
        XCTAssertNil(identity.sku, "two SKUs claim this ISBN, so neither is a safe guess")
    }

    func testNamedVolumeStillTakesItsSKUFromTheVolumeName() throws {
        let mountPoint = try makeMountPoint(volumeName: "BK-74107-CLAE", idText: "9781234567897")

        let identity = DriveVerifier.detectIdentity(mountPoint: mountPoint)

        XCTAssertFalse(identity.genericVolume)
        XCTAssertEqual(identity.sku, "BK-74107-CLAE")
    }

    func testVerifyAcceptsAMYOBlockIdentifiedOnlyByItsISBN() async throws {
        // An ISBN no catalog or master knows, so there is no SKU to find.
        let mountPoint = try makeMountPoint(volumeName: "VOXBLOCK", idText: "5061050100001")

        let result = try await DriveVerifier.verify(
            mountPoint: mountPoint, rawDevicePath: nil, checks: [], deepAudioInspect: false
        )

        XCTAssertTrue(result.isValid, "validation errors: \(result.validationErrors)")
        XCTAssertEqual(result.detectedISBN, "5061050100001")
        XCTAssertNil(result.detectedSKU)
    }

    func testVerifyOfAMYOBlockRecordsTheSKUFoundFromItsISBN() async throws {
        let log = try makeProductionLog()
        try recordKnownMaster(log, sku: "BK-26657-MYOB", isbn: "5061050126657")
        let mountPoint = try makeMountPoint(volumeName: "VOXBLOCK", idText: "5061050126657")

        let result = try await DriveVerifier.verify(
            mountPoint: mountPoint, rawDevicePath: nil, checks: [], deepAudioInspect: false, productionLog: log
        )

        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.detectedSKU, "BK-26657-MYOB")
        XCTAssertEqual(try log.master(sku: "BK-26657-MYOB")?.isbn, "5061050126657")
    }

    func testVerifyStillRejectsAMYOBlockWithNoISBN() async throws {
        let mountPoint = try makeMountPoint(volumeName: "VOXBLOCK", idText: nil)

        do {
            _ = try await DriveVerifier.verify(
                mountPoint: mountPoint, rawDevicePath: nil, checks: [], deepAudioInspect: false
            )
            XCTFail("a block with no ISBN can't be identified")
        } catch let error as DriveVerifierError {
            guard case .verificationFailed(let errors, _) = error else {
                XCTFail("expected verificationFailed, got \(error)")
                return
            }
            XCTAssertTrue(errors.contains { $0.contains("ISBN") })
            XCTAssertFalse(errors.contains { $0.contains("SKU") }, "a VOXBLOCK name was never going to carry a SKU")
        }
    }

    func testVerifyStillRejectsAnUnrelatedVolumeNameWithoutASKU() async throws {
        let mountPoint = try makeMountPoint(volumeName: "UNTITLED", idText: "5061050100001")

        do {
            _ = try await DriveVerifier.verify(
                mountPoint: mountPoint, rawDevicePath: nil, checks: [], deepAudioInspect: false
            )
            XCTFail("only a VOXBLOCK volume is exempt from needing a SKU in its name")
        } catch let error as DriveVerifierError {
            guard case .verificationFailed(let errors, _) = error else {
                XCTFail("expected verificationFailed, got \(error)")
                return
            }
            XCTAssertTrue(errors.contains { $0.contains("SKU") })
        }
    }
}

// MARK: - Synthetic ID3v2.3 tag construction
//
// Builds just enough of a real ID3v2.3 tag (10-byte header + one or
// more 10-byte-header frames) to exercise ID3Tag's parser without
// needing mutagen or a real MP3 encoder -- readID3v2Frames only reads
// the header-declared tag size, so nothing needs to follow it in the
// file.

private func id3v23Frame(id: String, body: Data) -> Data {
    var frame = Data(id.utf8)
    frame.append(bigEndianBytes(body.count))
    frame.append(Data([0, 0])) // flags
    frame.append(body)
    return frame
}

private func id3TextFrameBody(_ text: String) -> Data {
    var body = Data([3]) // UTF-8 encoding byte
    body.append(Data(text.utf8))
    return body
}

private func id3TXXXFrameBody(desc: String, value: String) -> Data {
    var body = Data([3]) // UTF-8 encoding byte
    body.append(Data(desc.utf8))
    body.append(Data([0])) // description/value separator
    body.append(Data(value.utf8))
    return body
}

private func buildID3v23Tag(frames: [Data]) -> Data {
    let frameData = frames.reduce(Data(), +)
    var header = Data([0x49, 0x44, 0x33, 3, 0, 0]) // "ID3", v2.3, no flags
    header.append(synchsafeBytes(frameData.count))
    return header + frameData
}

private func synchsafeBytes(_ value: Int) -> Data {
    Data([
        UInt8((value >> 21) & 0x7F),
        UInt8((value >> 14) & 0x7F),
        UInt8((value >> 7) & 0x7F),
        UInt8(value & 0x7F),
    ])
}

private func bigEndianBytes(_ value: Int) -> Data {
    Data([
        UInt8((value >> 24) & 0xFF),
        UInt8((value >> 16) & 0xFF),
        UInt8((value >> 8) & 0xFF),
        UInt8(value & 0xFF),
    ])
}
