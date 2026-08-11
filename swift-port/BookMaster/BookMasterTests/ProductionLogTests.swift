import XCTest
@testable import BookMaster

final class ProductionLogTests: XCTestCase {
    private func makeLog() throws -> (ProductionLog, URL) {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("test-\(UUID().uuidString).db")
        let db = try AppDatabase(path: path)
        return (ProductionLog(db: db), path)
    }

    private func cleanup(_ path: URL) {
        try? FileManager.default.removeItem(at: path)
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: path.path + "-wal"))
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: path.path + "-shm"))
    }

    func testSchemaCreationIsIdempotent() throws {
        let (_, path) = try makeLog()
        defer { cleanup(path) }
        // Opening a second connection against the same file re-runs
        // migrate()'s `CREATE TABLE IF NOT EXISTS` -- must not throw.
        XCTAssertNoThrow(try AppDatabase(path: path))
    }

    func testUpsertDeviceInsertsThenUpdatesLastSeen() throws {
        let (log, path) = try makeLog()
        defer { cleanup(path) }

        let id1 = try log.upsertDevice(vid: "0781", pid: "5567", serial: "ABC123")
        let id2 = try log.upsertDevice(vid: "0781", pid: "5567", serial: "ABC123")
        XCTAssertEqual(id1, id2, "same serial must resolve to the same device row")

        let device = try log.device(serial: "ABC123")
        XCTAssertEqual(device?.vid, "0781")
    }

    func testUpsertDeviceGivesUnknownSerialsDistinctEphemeralIdentities() throws {
        let (log, path) = try makeLog()
        defer { cleanup(path) }

        let id1 = try log.upsertDevice(vid: "0781", pid: "5567", serial: "UNKNOWN")
        let id2 = try log.upsertDevice(vid: "0781", pid: "5567", serial: "")
        XCTAssertNotEqual(id1, id2, "two different unreadable-serial devices must not collapse into one row")
    }

    func testMasterCatalogUpsertRoundTrips() throws {
        let (log, path) = try makeLog()
        defer { cleanup(path) }

        try log.upsertMasterCatalog(
            sku: "BK-12345-TEST", imgPath: "/tmp/x.img", imageBytes: 500_000_000,
            imageMib1dp: 476.8, usedMib1dp: 300.0, imageFileCount: 10, imageTrackCount: 9, imageIsbn: "9781234567897"
        )
        let master = try log.master(sku: "BK-12345-TEST")
        XCTAssertEqual(master?.imageFileCount, 10)
        XCTAssertEqual(master?.imageIsbn, "9781234567897")

        // Re-upserting the same SKU updates in place rather than duplicating.
        try log.upsertMasterCatalog(
            sku: "BK-12345-TEST", imgPath: "/tmp/x.img", imageBytes: 500_000_000,
            imageMib1dp: 476.8, usedMib1dp: 310.0, imageFileCount: 11, imageTrackCount: 10, imageIsbn: "9781234567897"
        )
        XCTAssertEqual(try log.allMasters().count, 1)
        XCTAssertEqual(try log.master(sku: "BK-12345-TEST")?.imageFileCount, 11)
    }

    func testRecordVerificationPreservesReadSpeedWhenNewValueIsNil() throws {
        let (log, path) = try makeLog()
        defer { cleanup(path) }

        try log.recordVerification(sku: "BK-1", serial: "SER1", isbn: "978", trackCount: 5, readMibS: 42.0, stickUsedMib1dp: 100.0)
        XCTAssertEqual(try log.master(sku: "BK-1")?.readMibS, 42.0)

        // A later verify with --no-speed-test (readMibS == nil) must not wipe the prior reading.
        try log.recordVerification(sku: "BK-1", serial: "SER1", isbn: "978", trackCount: 5, readMibS: nil, stickUsedMib1dp: 100.0)
        XCTAssertEqual(try log.master(sku: "BK-1")?.readMibS, 42.0)
    }

    func testDeviceHistoryAggregatesWritesAndDuplicatorRuns() throws {
        let (log, path) = try makeLog()
        defer { cleanup(path) }

        let deviceId = try log.upsertDevice(vid: "0781", pid: "5567", serial: "SER-HISTORY")
        try log.upsertMasterCatalog(sku: "BK-1", imgPath: "/tmp/1.img", imageBytes: 1, imageMib1dp: 1, usedMib1dp: 1, imageFileCount: 1, imageTrackCount: 1, imageIsbn: nil)
        try log.insertWrite(sku: "BK-1", deviceId: deviceId, diskId: "/dev/disk4", elapsedS: 30, throughputUsedMibS: 10, throughputImageMibS: 12, trackCount: 5, tracksPath: "/Volumes/BK1/tracks", imgPath: "/tmp/1.img")

        let dupeRow = DupeRow(
            runIndex: 1, dt: "2026-01-01 00:00:00", port: "1", result: "PASS", functionRaw: "COPY", functionName: "copy",
            timeRaw: "1:00", capacityRaw: "1.9GB(4000000)", capacityMib: 1953.1, sectors: 4000000, dataMib: 100, dataMib1dp: 100.0,
            speedFactor: 1.67, writeSpeedMibS: 1.67, readSpeedMibS: nil, vid: "0781", pid: "5567",
            serial: "SER-HISTORY", notes: "", rawLine: "raw"
        )
        try log.insertDuplicatorRuns(sourceFile: "test.log", rows: [dupeRow])

        let history = try log.deviceHistory(serial: "SER-HISTORY")
        XCTAssertFalse(history.isEmpty)
        XCTAssertEqual(history.writes.count, 1)
        XCTAssertEqual(history.duplicatorRuns.count, 1)
        XCTAssertEqual(history.device?.serial, "SER-HISTORY")

        // A device that was never written to or ingested has empty (not error) history.
        let emptyHistory = try log.deviceHistory(serial: "NEVER-SEEN")
        XCTAssertTrue(emptyHistory.isEmpty)
    }

    func testMatchDuplicatorRunsClassifiesUniqueAmbiguousAndNoMatch() throws {
        let (log, path) = try makeLog()
        defer { cleanup(path) }

        // Two masters share the same used_mib_1dp (100.0) -> ambiguous.
        try log.upsertMasterCatalog(sku: "BK-A", imgPath: "/a.img", imageBytes: 1, imageMib1dp: 1, usedMib1dp: 100.0, imageFileCount: 1, imageTrackCount: 1, imageIsbn: nil)
        try log.upsertMasterCatalog(sku: "BK-B", imgPath: "/b.img", imageBytes: 1, imageMib1dp: 1, usedMib1dp: 100.0, imageFileCount: 1, imageTrackCount: 1, imageIsbn: nil)
        // One master with a unique size -> unique match.
        try log.upsertMasterCatalog(sku: "BK-C", imgPath: "/c.img", imageBytes: 1, imageMib1dp: 1, usedMib1dp: 250.0, imageFileCount: 1, imageTrackCount: 1, imageIsbn: nil)

        func row(dataMib: Double, index: Int) -> DupeRow {
            DupeRow(runIndex: index, dt: "2026-01-0\(index) 00:00:00", port: "1", result: "PASS", functionRaw: "COPY",
                    functionName: "copy", timeRaw: "1:00", capacityRaw: nil, capacityMib: nil, sectors: nil,
                    dataMib: dataMib, dataMib1dp: dataMib, speedFactor: nil, writeSpeedMibS: nil, readSpeedMibS: nil,
                    vid: nil, pid: nil, serial: "SER\(index)", notes: "", rawLine: "raw\(index)")
        }
        try log.insertDuplicatorRuns(sourceFile: "t.log", rows: [
            row(dataMib: 100.0, index: 1), // ambiguous (BK-A, BK-B)
            row(dataMib: 250.0, index: 2), // unique (BK-C)
            row(dataMib: 999.0, index: 3), // no_match
        ])

        let matches = try log.matchDuplicatorRuns()
        XCTAssertEqual(matches.count, 3)

        let ambiguous = matches.first { $0.serial == "SER1" }
        XCTAssertEqual(ambiguous?.matchStatus, "ambiguous")
        XCTAssertEqual(Set(ambiguous?.candidateSkus ?? []), Set(["BK-A", "BK-B"]))

        let unique = matches.first { $0.serial == "SER2" }
        XCTAssertEqual(unique?.matchStatus, "unique")
        XCTAssertEqual(unique?.candidateSkus, ["BK-C"])

        let noMatch = matches.first { $0.serial == "SER3" }
        XCTAssertEqual(noMatch?.matchStatus, "no_match")
        XCTAssertEqual(noMatch?.candidateSkus, [])

        let stats = try log.stats()
        XCTAssertEqual(stats.totalDuplicatorRuns, 3)
        XCTAssertEqual(stats.uniqueMatches, 1)
        XCTAssertEqual(stats.ambiguousMatches, 1)
        XCTAssertEqual(stats.unmatchedRuns, 1)
    }
}
