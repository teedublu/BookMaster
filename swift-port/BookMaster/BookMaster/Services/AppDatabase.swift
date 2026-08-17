import Foundation
import SQLite3

public enum DatabaseError: Error, CustomStringConvertible {
    case openFailed(String)
    case sqlFailed(sql: String, message: String)

    public var description: String {
        switch self {
        case .openFailed(let msg): return "could not open database: \(msg)"
        case .sqlFailed(let sql, let msg): return "SQL failed (\(msg)): \(sql)"
        }
    }
}

/// A row of column-name -> value, generic enough to cover every query in
/// this file without a per-table Codable/reflection layer. Typed record
/// structs (see DatabaseRecords.swift) are built FROM these dictionaries
/// at the call site, keeping the SQL layer itself simple.
public typealias DBRow = [String: DBValue]

public enum DBValue {
    case text(String)
    case int(Int64)
    case real(Double)
    case null

    public var stringValue: String? { if case .text(let s) = self { return s }; return nil }
    public var intValue: Int? { if case .int(let i) = self { return Int(i) }; return nil }
    public var int64Value: Int64? { if case .int(let i) = self { return i }; return nil }
    public var doubleValue: Double? {
        switch self {
        case .real(let d): return d
        case .int(let i): return Double(i)
        default: return nil
        }
    }
}

/// Ports voxmaster's db.py: a SQLite-backed production log covering
/// masters (one row per SKU, latest known stats), devices (one row per
/// physical USB device, keyed by serial), writes (one row per physical
/// write of a master to a device), and duplicator_runs (ingested from
/// hardware USB duplicator log files). Uses the system SQLite3 C API
/// directly rather than a third-party wrapper, matching this port's
/// established no-dependencies pattern -- the schema is fixed and known
/// up front, so the verbosity of manual prepare/bind/step is worth it to
/// avoid pulling in GRDB/SQLite.swift for four tables.
///
/// Deliberately NOT ported: db.py's legacy-schema migration functions
/// (_rebuild_masters, _merge_legacy_verifications_into_masters_and_drop,
/// _rebuild_duplicator_runs). Those exist to migrate an existing
/// production database through several past schema versions; a fresh
/// Swift database has no such history to migrate, so it just creates the
/// current target schema directly.
public final class AppDatabase {
    private var handle: OpaquePointer?
    public let path: URL

    public static func defaultPath() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BookMasterSwift", isDirectory: true)
        return resolvedPath(inDirectory: dir)
    }

    /// Resolves the database file inside `directory` (a local folder or a
    /// mounted network share), creating the directory if needed. Used for
    /// both the local default and a user-configured network location
    /// (Settings.databasePath) so the same "voxmaster.db" filename and
    /// directory-creation behavior applies either way.
    public static func resolvedPath(inDirectory directory: URL) -> URL {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("voxmaster.db")
    }

    public init(path: URL) throws {
        self.path = path
        var db: OpaquePointer?
        guard sqlite3_open(path.path, &db) == SQLITE_OK else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(db)
            throw DatabaseError.openFailed(msg)
        }
        self.handle = db
        try migrate()
    }

    deinit {
        sqlite3_close(handle)
    }

    // MARK: - Schema

    private func migrate() throws {
        // NOT WAL: SQLite's own docs call WAL mode unsupported over network
        // filesystems (SMB/AFP/NFS) -- it relies on shared-memory mapping
        // of a -shm sidecar file that network protocols don't reliably
        // provide, risking silent corruption even for a single writer.
        // This database is meant to live on a mounted network share (see
        // Settings.databasePath), so the classic rollback journal -- no
        // shared memory, cleans up its journal file after every
        // transaction -- is the safe choice here, not just the default.
        try execute("PRAGMA journal_mode=DELETE;")
        try execute("""
        CREATE TABLE IF NOT EXISTS masters (
          sku TEXT PRIMARY KEY,
          img_path TEXT,
          image_bytes INTEGER,
          image_mib_1dp REAL,
          used_mib_1dp REAL,
          image_file_count INTEGER,
          image_track_count INTEGER,
          image_isbn TEXT,
          created_at TEXT,
          modified_at TEXT,
          serial TEXT,
          isbn TEXT,
          track_count INTEGER,
          read_mib_s REAL,
          last_stick_used_mib_1dp REAL,
          updated_at TEXT NOT NULL
        );
        """)
        try execute("""
        CREATE TABLE IF NOT EXISTS devices (
          device_id INTEGER PRIMARY KEY AUTOINCREMENT,
          vid TEXT NOT NULL,
          pid TEXT NOT NULL,
          serial TEXT NOT NULL,
          first_seen_at TEXT NOT NULL,
          last_seen_at TEXT NOT NULL,
          UNIQUE(serial)
        );
        """)
        try execute("""
        CREATE TABLE IF NOT EXISTS writes (
          write_id INTEGER PRIMARY KEY AUTOINCREMENT,
          timestamp TEXT NOT NULL,
          sku TEXT NOT NULL,
          device_id INTEGER NOT NULL,
          disk_id TEXT NOT NULL,
          elapsed_s INTEGER NOT NULL,
          throughput_used_mib_s REAL NOT NULL,
          throughput_image_mib_s REAL NOT NULL,
          track_count INTEGER NOT NULL,
          tracks_path TEXT,
          img_path TEXT NOT NULL,
          FOREIGN KEY(sku) REFERENCES masters(sku),
          FOREIGN KEY(device_id) REFERENCES devices(device_id)
        );
        """)
        try execute("""
        CREATE TABLE IF NOT EXISTS duplicator_runs (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          source_file TEXT,
          run_index INTEGER,
          dt TEXT,
          port TEXT,
          result TEXT,
          function_name TEXT,
          function_raw TEXT,
          time_raw TEXT,
          data_mib REAL,
          data_mib_1dp REAL,
          capacity_raw TEXT,
          capacity_mib REAL,
          sectors INTEGER,
          speed_factor REAL,
          write_speed_mib_s REAL,
          read_speed_mib_s REAL,
          vid TEXT,
          pid TEXT,
          serial TEXT,
          notes TEXT,
          raw_line TEXT
        );
        """)
        try execute("CREATE INDEX IF NOT EXISTS idx_dupe_dt ON duplicator_runs(dt);")
        try execute("CREATE INDEX IF NOT EXISTS idx_dupe_serial ON duplicator_runs(serial);")
        try execute("CREATE INDEX IF NOT EXISTS idx_dupe_data_mib ON duplicator_runs(data_mib_1dp);")

        // Master-block lineage: unlike `masters` (one row per SKU,
        // overwritten on every build/verify), these are append-only event
        // logs. `master_builds` keeps every build attempt instead of just
        // the latest, so a regression between build N-1 and N is visible.
        // `master_checks` is row-per-check rather than fixed columns so a
        // new QA check (see MasterContentAuditor) is an insert, not a
        // migration. `master_writes`/`master_verifications` separate
        // "wrote a master image onto this physical block" from "confirmed
        // this block's content is accurate" -- a block can be verified
        // again later without a new write, e.g. before it's handed to the
        // duplicator machine or the factory. Deliberately scoped to the
        // master block only, not the sellable units later cloned from it
        // by the USB duplicator machine -- that's a different physical
        // write with different failure modes and isn't tracked here yet.
        try execute("""
        CREATE TABLE IF NOT EXISTS master_builds (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          sku TEXT NOT NULL,
          isbn TEXT,
          built_at TEXT NOT NULL,
          img_path TEXT NOT NULL,
          image_bytes INTEGER,
          image_mib_1dp REAL,
          used_mib_1dp REAL,
          file_count INTEGER,
          track_count INTEGER,
          checksum TEXT,
          status TEXT NOT NULL
        );
        """)
        try execute("CREATE INDEX IF NOT EXISTS idx_master_builds_sku ON master_builds(sku);")

        try execute("""
        CREATE TABLE IF NOT EXISTS master_checks (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          build_id INTEGER NOT NULL,
          check_type TEXT NOT NULL,
          expected_value TEXT,
          actual_value TEXT,
          passed INTEGER NOT NULL,
          message TEXT,
          checked_at TEXT NOT NULL,
          FOREIGN KEY(build_id) REFERENCES master_builds(id)
        );
        """)
        try execute("CREATE INDEX IF NOT EXISTS idx_master_checks_build ON master_checks(build_id);")

        try execute("""
        CREATE TABLE IF NOT EXISTS master_writes (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          device_id INTEGER NOT NULL,
          master_build_id INTEGER,
          sku TEXT NOT NULL,
          written_at TEXT NOT NULL,
          elapsed_s INTEGER NOT NULL,
          throughput_image_mib_s REAL NOT NULL,
          throughput_used_mib_s REAL NOT NULL,
          track_count_written INTEGER NOT NULL,
          found_artifact_count INTEGER NOT NULL,
          removed_artifact_count INTEGER NOT NULL,
          disk_id TEXT,
          FOREIGN KEY(device_id) REFERENCES devices(device_id),
          FOREIGN KEY(master_build_id) REFERENCES master_builds(id)
        );
        """)
        try execute("CREATE INDEX IF NOT EXISTS idx_master_writes_device ON master_writes(device_id);")
        try execute("CREATE INDEX IF NOT EXISTS idx_master_writes_sku ON master_writes(sku);")

        try execute("""
        CREATE TABLE IF NOT EXISTS master_verifications (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          device_id INTEGER,
          master_write_id INTEGER,
          sku TEXT,
          detected_sku TEXT,
          detected_isbn TEXT,
          track_count INTEGER NOT NULL,
          stick_used_mib REAL,
          tracks_size_mib REAL,
          read_speed_mib_s REAL,
          expected_duration_s INTEGER,
          encoding_kbps REAL,
          encoding_rate_anomaly INTEGER NOT NULL,
          found_artifact_count INTEGER NOT NULL,
          id3_issue_count INTEGER NOT NULL,
          validation_errors TEXT,
          passed INTEGER NOT NULL,
          verified_at TEXT NOT NULL,
          FOREIGN KEY(device_id) REFERENCES devices(device_id),
          FOREIGN KEY(master_write_id) REFERENCES master_writes(id)
        );
        """)
        try execute("CREATE INDEX IF NOT EXISTS idx_master_verifications_device ON master_verifications(device_id);")
        try execute("CREATE INDEX IF NOT EXISTS idx_master_verifications_sku ON master_verifications(sku);")
    }

    // MARK: - Low-level execute / query

    @discardableResult
    public func execute(_ sql: String, _ bindings: [DBValue?] = []) throws -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.sqlFailed(sql: sql, message: lastErrorMessage())
        }
        defer { sqlite3_finalize(stmt) }
        try bind(bindings, to: stmt)
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw DatabaseError.sqlFailed(sql: sql, message: lastErrorMessage())
        }
        return Int(sqlite3_changes(handle))
    }

    public func query(_ sql: String, _ bindings: [DBValue?] = []) throws -> [DBRow] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.sqlFailed(sql: sql, message: lastErrorMessage())
        }
        defer { sqlite3_finalize(stmt) }
        try bind(bindings, to: stmt)

        var rows: [DBRow] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                rows.append(readRow(stmt))
            } else if rc == SQLITE_DONE {
                break
            } else {
                throw DatabaseError.sqlFailed(sql: sql, message: lastErrorMessage())
            }
        }
        return rows
    }

    public var lastInsertRowID: Int64 {
        sqlite3_last_insert_rowid(handle)
    }

    private func bind(_ bindings: [DBValue?], to stmt: OpaquePointer?) throws {
        for (index, value) in bindings.enumerated() {
            let i = Int32(index + 1)
            switch value {
            case .none, .some(.null):
                sqlite3_bind_null(stmt, i)
            case .some(.text(let s)):
                sqlite3_bind_text(stmt, i, s, -1, SQLITE_TRANSIENT)
            case .some(.int(let n)):
                sqlite3_bind_int64(stmt, i, n)
            case .some(.real(let d)):
                sqlite3_bind_double(stmt, i, d)
            }
        }
    }

    private func readRow(_ stmt: OpaquePointer?) -> DBRow {
        var row: DBRow = [:]
        let count = sqlite3_column_count(stmt)
        for i in 0..<count {
            let name = String(cString: sqlite3_column_name(stmt, i))
            switch sqlite3_column_type(stmt, i) {
            case SQLITE_INTEGER:
                row[name] = .int(sqlite3_column_int64(stmt, i))
            case SQLITE_FLOAT:
                row[name] = .real(sqlite3_column_double(stmt, i))
            case SQLITE_TEXT:
                row[name] = .text(String(cString: sqlite3_column_text(stmt, i)))
            default:
                row[name] = .null
            }
        }
        return row
    }

    private func lastErrorMessage() -> String {
        String(cString: sqlite3_errmsg(handle))
    }
}

// SQLITE_TRANSIENT tells SQLite to copy the string, since Swift's String
// -> C string bridging doesn't guarantee the buffer outlives the call.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
