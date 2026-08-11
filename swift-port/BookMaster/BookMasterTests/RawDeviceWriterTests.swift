import XCTest
import CryptoKit
@testable import BookMaster

final class RawDeviceWriterTests: XCTestCase {

    // MARK: - Write mechanics (against a scratch file, never a real device)

    func testWriteRoundTripsChecksum() throws {
        let fm = FileManager.default
        let sourcePath = fm.temporaryDirectory.appendingPathComponent("rdw-source-\(UUID().uuidString).img")
        let targetPath = fm.temporaryDirectory.appendingPathComponent("rdw-target-\(UUID().uuidString).img")
        defer {
            try? fm.removeItem(at: sourcePath)
            try? fm.removeItem(at: targetPath)
        }

        var sourceData = Data(count: 10 * 1024 * 1024)
        sourceData.withUnsafeMutableBytes { (buf: UnsafeMutableRawBufferPointer) in
            for i in 0..<buf.count { buf[i] = UInt8.random(in: 0...255) }
        }
        try sourceData.write(to: sourcePath)
        fm.createFile(atPath: targetPath.path, contents: nil)

        // authorization normally requires a real /dev/rdiskN target; here
        // we exercise write() directly against a fabricated authorization
        // pointed at a scratch file, mirroring Phase 0's RawWriteSpike.
        let auth = TestHelpers.fakeAuthorization(rawDevicePath: targetPath.path)

        var progressUpdates: [Double] = []
        let written = try RawDeviceWriter.write(imageAt: sourcePath, authorization: auth, chunkSize: 1024 * 1024) { pct in
            progressUpdates.append(pct)
        }

        XCTAssertEqual(written, Int64(sourceData.count))
        XCTAssertEqual(SHA256.hash(data: sourceData).description, SHA256.hash(data: try Data(contentsOf: targetPath)).description)
        XCTAssertFalse(progressUpdates.isEmpty)
        XCTAssertEqual(progressUpdates.last, 1.0)
    }

    func testWriteThrowsOnMissingSource() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString).img")
        let auth = TestHelpers.fakeAuthorization(rawDevicePath: "/dev/null")
        XCTAssertThrowsError(try RawDeviceWriter.write(imageAt: missing, authorization: auth))
    }

    // MARK: - Double safety gate

    private func makeDrive(bsdName: String, removable: Bool, whole: Bool, proto: String) -> USBDriveInfo {
        USBDriveInfo(
            bsdName: bsdName, rawDevicePath: "/dev/r\(bsdName)",
            isRemovable: removable, isEjectable: removable, isWhole: whole,
            protocolName: proto, sizeBytes: 1_000_000_000,
            mediaName: nil, volumeName: "TEST", volumeKind: "msdos", mountPath: "/Volumes/TEST",
            totalCapacityBytes: nil, availableCapacityBytes: nil
        )
    }

    func testAuthorizeSucceedsForRealUSBCandidate() {
        let drive = makeDrive(bsdName: "disk4", removable: true, whole: true, proto: "USB")
        let result = RawWriteAuthorization.authorize(drive: drive, currentCandidates: [drive])
        switch result {
        case .success(let auth): XCTAssertEqual(auth.rawDevicePath, "/dev/rdisk4")
        case .failure(let e): XCTFail("expected success, got \(e)")
        }
    }

    /// The exact scenario from Phase 0: a real machine's boot disk
    /// (disk0) matches the /dev/rdiskN path pattern but must never be
    /// authorized as a write target.
    func testAuthorizeRejectsInternalBootDiskDespitePatternMatch() {
        let disk0 = makeDrive(bsdName: "disk0", removable: false, whole: true, proto: "Apple Fabric")
        XCTAssertTrue(RawWriteAuthorization.isAllowedRawTargetPattern(disk0.rawDevicePath), "sanity: disk0 does match the naive pattern")

        let result = RawWriteAuthorization.authorize(drive: disk0, currentCandidates: [disk0])
        switch result {
        case .success: XCTFail("must never authorize a non-removable internal disk")
        case .failure(let e):
            guard case .targetNotCurrentlyACandidate = e else {
                XCTFail("expected targetNotCurrentlyACandidate, got \(e)")
                return
            }
        }
    }

    /// CoreSimulator-style: removable but not USB (Phase 0/2's finding).
    func testAuthorizeRejectsRemovableNonUSBDevice() {
        let simVolume = makeDrive(bsdName: "disk5", removable: true, whole: true, proto: "Virtual Interface")
        let result = RawWriteAuthorization.authorize(drive: simVolume, currentCandidates: [simVolume])
        XCTAssertNil(try? result.get())
    }

    func testAuthorizeRejectsSliceNotWholeDisk() {
        var slice = makeDrive(bsdName: "disk4s1", removable: true, whole: false, proto: "USB")
        slice.rawDevicePath = "/dev/rdisk4s1"
        let result = RawWriteAuthorization.authorize(drive: slice, currentCandidates: [slice])
        switch result {
        case .success: XCTFail("must never authorize a partition slice, only a whole disk")
        case .failure(let e):
            guard case .targetNotAllowedByPattern = e else {
                XCTFail("expected targetNotAllowedByPattern, got \(e)")
                return
            }
        }
    }

    /// The core "live re-check" property: a device that WAS a candidate
    /// when the user selected it, but no longer is by write time (e.g.
    /// unplugged and something else took the same BSD name), must be
    /// rejected even though the caller passed in a snapshot that looks fine.
    func testAuthorizeRejectsWhenNoLongerInCurrentCandidateList() {
        let staleSelection = makeDrive(bsdName: "disk4", removable: true, whole: true, proto: "USB")
        let result = RawWriteAuthorization.authorize(drive: staleSelection, currentCandidates: [])
        XCTAssertNil(try? result.get(), "a device absent from the live candidate list must never be authorized")
    }

    /// Phase 8 gap-closing: same bsdName, but the live candidate's
    /// rawDevicePath disagrees with what the caller passed in (e.g. a
    /// BSD name got reused for a different physical device between
    /// selection and write). Must reject rather than trust the caller's
    /// path over the live lookup's.
    func testAuthorizeRejectsWhenRawDevicePathDisagreesWithLiveCandidate() {
        let staleSelection = makeDrive(bsdName: "disk4", removable: true, whole: true, proto: "USB")
        var currentButDifferentPath = staleSelection
        currentButDifferentPath.rawDevicePath = "/dev/rdisk7" // same bsdName, different actual device path
        let result = RawWriteAuthorization.authorize(drive: staleSelection, currentCandidates: [currentButDifferentPath])
        XCTAssertNil(try? result.get(), "a raw device path mismatch between selection and live state must never be authorized")
    }
}

enum TestHelpers {
    /// Constructs a `RawWriteAuthorization` directly (bypassing
    /// `authorize()`'s pattern/candidate gates, which are tested
    /// separately and exhaustively) so `RawDeviceWriter.write()`'s I/O
    /// mechanics can be tested against an arbitrary scratch file instead
    /// of requiring a real `/dev/rdiskN` device.
    static func fakeAuthorization(rawDevicePath: String) -> RawWriteAuthorization {
        RawWriteAuthorization(bsdName: "diskTEST", rawDevicePath: rawDevicePath)
    }
}
