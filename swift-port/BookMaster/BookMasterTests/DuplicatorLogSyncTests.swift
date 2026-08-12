import XCTest
@testable import BookMaster

final class DuplicatorLogSyncTests: XCTestCase {
    private func makeLog() throws -> (ProductionLog, URL) {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("dupesync-db-\(UUID().uuidString).db")
        let db = try AppDatabase(path: path)
        return (ProductionLog(db: db), path)
    }

    private func cleanupDB(_ path: URL) {
        try? FileManager.default.removeItem(at: path)
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: path.path + "-wal"))
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: path.path + "-shm"))
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: path.path + "-journal"))
    }

    private func writeLogFile(named name: String, in folder: URL, serial: String) throws {
        let line = "0000001 2026-01-01 10:00:00  0001  PASS            COPY(DATA,100.0MB)                     00:10          1.9GB(4014080)      0781h 5567h [\(serial)]"
        try (line + "\n").write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func testSyncIngestsNewFilesAndSkipsAlreadySyncedOnesByFilename() async throws {
        let (log, dbPath) = try makeLog()
        defer { cleanupDB(dbPath) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("dupesync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        try writeLogFile(named: "20260101-000001.txt", in: folder, serial: "1111111111111")
        try writeLogFile(named: "20260101-000002.txt", in: folder, serial: "2222222222222")

        let first = await DuplicatorLogSync.sync(folder: folder, productionLog: log)
        XCTAssertEqual(Set(first.syncedFileNames), ["20260101-000001.txt", "20260101-000002.txt"])
        XCTAssertEqual(first.rowsInserted, 2)
        XCTAssertEqual(first.skippedAlreadySyncedCount, 0)

        // A second sync against the same folder, with one new file added,
        // must not re-ingest (and duplicate) the first two.
        try writeLogFile(named: "20260101-000003.txt", in: folder, serial: "3333333333333")
        let second = await DuplicatorLogSync.sync(folder: folder, productionLog: log)
        XCTAssertEqual(second.syncedFileNames, ["20260101-000003.txt"])
        XCTAssertEqual(second.skippedAlreadySyncedCount, 2)
        XCTAssertEqual(second.rowsInserted, 1)

        let stats = try log.stats()
        XCTAssertEqual(stats.totalDuplicatorRuns, 3, "no duplicate rows from re-scanning already-synced files")
    }

    func testSyncOfEmptyOrUnreadableFolderReturnsEmptySummaryRatherThanCrashing() async throws {
        let (log, dbPath) = try makeLog()
        defer { cleanupDB(dbPath) }
        let missingFolder = FileManager.default.temporaryDirectory.appendingPathComponent("does-not-exist-\(UUID().uuidString)")

        let summary = await DuplicatorLogSync.sync(folder: missingFolder, productionLog: log)
        XCTAssertTrue(summary.isEmpty)
        XCTAssertEqual(summary.rowsInserted, 0)
    }

    func testIgnoresNonLogFilesInTheFolder() async throws {
        let (log, dbPath) = try makeLog()
        defer { cleanupDB(dbPath) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("dupesync-mixed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        try writeLogFile(named: "real.txt", in: folder, serial: "1111111111111")
        try "not a log".write(to: folder.appendingPathComponent(".DS_Store"), atomically: true, encoding: .utf8)
        try Data().write(to: folder.appendingPathComponent("cover.png"))

        let summary = await DuplicatorLogSync.sync(folder: folder, productionLog: log)
        XCTAssertEqual(summary.syncedFileNames, ["real.txt"])
    }
}
