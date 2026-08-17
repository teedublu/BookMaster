import XCTest
@testable import BookMaster

/// Covers the master-block lineage added alongside the existing flat
/// masters/writes tables: master_builds (append-only build history),
/// master_checks (content-completeness QA), and master_writes/
/// master_verifications (is a specific physical block an accurate copy).
final class ProductionLogMasterBlockTests: XCTestCase {
    private func makeLog() throws -> (ProductionLog, URL) {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("test-\(UUID().uuidString).db")
        let log = ProductionLog(db: try AppDatabase(path: path))
        return (log, path)
    }

    private func cleanup(_ path: URL) {
        try? FileManager.default.removeItem(at: path)
    }

    func testMasterBuildsAreAppendOnlyAndOrderedNewestFirst() throws {
        let (log, path) = try makeLog()
        defer { cleanup(path) }

        try log.insertMasterBuild(
            sku: "BK-0001-A", isbn: "9780000000001", imgPath: "/tmp/v1.img", imageBytes: 100,
            imageMib1dp: 1.0, usedMib1dp: 0.9, fileCount: 5, trackCount: 5, checksum: "abc"
        )
        try log.insertMasterBuild(
            sku: "BK-0001-A", isbn: "9780000000001", imgPath: "/tmp/v2.img", imageBytes: 200,
            imageMib1dp: 2.0, usedMib1dp: 1.9, fileCount: 6, trackCount: 6, checksum: "def"
        )

        let builds = try log.masterBuilds(sku: "BK-0001-A")
        XCTAssertEqual(builds.count, 2)
        XCTAssertEqual(builds.first?.imgPath, "/tmp/v2.img", "newest build should sort first")

        let latest = try log.latestMasterBuild(sku: "BK-0001-A")
        XCTAssertEqual(latest?.trackCount, 6)
    }

    func testMasterChecksAttachToABuild() throws {
        let (log, path) = try makeLog()
        defer { cleanup(path) }

        let buildId = try log.insertMasterBuild(
            sku: "BK-0002-A", isbn: nil, imgPath: "/tmp/x.img", imageBytes: nil,
            imageMib1dp: nil, usedMib1dp: nil, fileCount: nil, trackCount: 10, checksum: nil
        )
        try log.insertMasterCheck(
            buildId: buildId, checkType: "track_count", expectedValue: "12", actualValue: "10",
            passed: false, message: "2 tracks short of catalog expectation"
        )

        let checks = try log.masterChecks(buildId: buildId)
        XCTAssertEqual(checks.count, 1)
        XCTAssertEqual(checks.first?.checkType, "track_count")
        XCTAssertFalse(checks.first?.passed ?? true)
    }

    func testMasterBlockHistoryReflectsWriteAndAccurateVerification() throws {
        let (log, path) = try makeLog()
        defer { cleanup(path) }

        let buildId = try log.insertMasterBuild(
            sku: "BK-0003-A", isbn: "9780000000003", imgPath: "/tmp/master.img", imageBytes: 500,
            imageMib1dp: 5.0, usedMib1dp: 4.5, fileCount: 8, trackCount: 8, checksum: "checksum123"
        )
        let deviceId = try log.upsertDevice(vid: "0781", pid: "5583", serial: "SERIAL-001")

        try log.insertMasterWrite(
            deviceId: deviceId, masterBuildId: buildId, sku: "BK-0003-A", elapsedS: 42,
            throughputImageMibS: 12.0, throughputUsedMibS: 10.5, trackCountWritten: 8,
            foundArtifactCount: 1, removedArtifactCount: 1, diskId: "/dev/disk9"
        )
        try log.insertMasterVerification(
            deviceId: deviceId, masterWriteId: nil, sku: "BK-0003-A", detectedSku: "BK-0003-A",
            detectedIsbn: "9780000000003", trackCount: 8, stickUsedMib: 4.5, tracksSizeMib: 4.3,
            readSpeedMibS: 30.0, expectedDurationS: 3600, encodingKbps: 96.0, encodingRateAnomaly: false,
            foundArtifactCount: 0, id3IssueCount: 0, validationErrors: [], passed: true
        )

        let history = try log.masterBlockHistory(serial: "SERIAL-001")
        XCTAssertEqual(history.writes.count, 1)
        XCTAssertEqual(history.verifications.count, 1)
        XCTAssertEqual(history.isAccurate, true)
        XCTAssertEqual(history.writes.first?.masterBuildId, buildId)
    }

    func testMasterBlockHistoryReflectsFailedVerification() throws {
        let (log, path) = try makeLog()
        defer { cleanup(path) }

        let deviceId = try log.upsertDevice(vid: "0781", pid: "5583", serial: "SERIAL-002")
        try log.insertMasterVerification(
            deviceId: deviceId, masterWriteId: nil, sku: nil, detectedSku: nil, detectedIsbn: nil,
            trackCount: 0, stickUsedMib: nil, tracksSizeMib: nil, readSpeedMibS: nil,
            expectedDurationS: nil, encodingKbps: nil, encodingRateAnomaly: false,
            foundArtifactCount: 0, id3IssueCount: 0,
            validationErrors: ["SKU missing/invalid in volume name", "ISBN missing in id.txt"], passed: false
        )

        let history = try log.masterBlockHistory(serial: "SERIAL-002")
        XCTAssertEqual(history.isAccurate, false)
        XCTAssertEqual(history.verifications.first?.validationErrors, "SKU missing/invalid in volume name; ISBN missing in id.txt")
    }

    func testMasterBlockHistoryForUnknownSerialIsEmpty() throws {
        let (log, path) = try makeLog()
        defer { cleanup(path) }

        let history = try log.masterBlockHistory(serial: "NEVER-SEEN")
        XCTAssertTrue(history.isEmpty)
        XCTAssertNil(history.isAccurate)
    }
}
