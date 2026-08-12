import XCTest
@testable import BookMaster

final class AppDatabaseTests: XCTestCase {
    private func cleanup(_ path: URL) {
        try? FileManager.default.removeItem(at: path)
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: path.path + "-wal"))
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: path.path + "-shm"))
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: path.path + "-journal"))
    }

    // Not WAL: SQLite's own docs call WAL mode unsupported over network
    // filesystems, since it depends on shared-memory mapping of a -shm
    // sidecar file that network protocols don't reliably provide. This
    // database is meant to be relocatable onto a mounted network share
    // (Settings.databasePath), so asserting the rollback journal here is
    // a real safety requirement, not a style preference.
    func testJournalModeIsNotWAL() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("test-\(UUID().uuidString).db")
        defer { cleanup(path) }
        let db = try AppDatabase(path: path)

        let rows = try db.query("PRAGMA journal_mode;")
        XCTAssertEqual(rows.first?["journal_mode"]?.stringValue?.lowercased(), "delete")
    }

    func testJournalModeSurvivesReopenAgainstExistingWALDatabase() throws {
        // A database created before this change would already be in WAL
        // mode on disk; opening it again must convert it back, not just
        // leave the old mode in place.
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("test-\(UUID().uuidString).db")
        defer { cleanup(path) }
        do {
            let db = try AppDatabase(path: path)
            try db.execute("PRAGMA journal_mode=WAL;")
            let rows = try db.query("PRAGMA journal_mode;")
            XCTAssertEqual(rows.first?["journal_mode"]?.stringValue?.lowercased(), "wal")
        }
        let reopened = try AppDatabase(path: path)
        let rows = try reopened.query("PRAGMA journal_mode;")
        XCTAssertEqual(rows.first?["journal_mode"]?.stringValue?.lowercased(), "delete")
    }

    func testResolvedPathCreatesDirectoryAndAppendsFixedFilename() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("db-dir-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))

        let path = AppDatabase.resolvedPath(inDirectory: dir)

        XCTAssertEqual(path.lastPathComponent, "voxmaster.db")
        XCTAssertEqual(path.deletingLastPathComponent().path, dir.path)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }
}
