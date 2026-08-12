import Foundation

/// The typed operations this app performs against AppDatabase, ported
/// from voxmaster's db.py (upsert_device, insert_duplicator_runs) plus
/// the reconciliation query from exporter.py's export_matches()/stats().
public final class ProductionLog {
    public let db: AppDatabase

    public init(db: AppDatabase) {
        self.db = db
    }

    public convenience init() throws {
        self.init(db: try AppDatabase(path: AppDatabase.defaultPath()))
    }

    // MARK: - Devices

    /// Ports db.py's upsert_device(): looks up a device by serial,
    /// updating last-seen if found, inserting if not. A blank/"UNKNOWN"
    /// serial gets a synthetic EPHEMERAL-<timestamp>-<random> identity
    /// rather than collapsing multiple physical devices with unreadable
    /// serials into one row.
    @discardableResult
    public func upsertDevice(vid: String, pid: String, serial: String) throws -> Int {
        let now = Self.isoNow()
        var serialNorm = serial.trimmingCharacters(in: .whitespacesAndNewlines)
        if serialNorm.isEmpty || serialNorm.uppercased() == "UNKNOWN" {
            serialNorm = "EPHEMERAL-\(now)-\(UUID().uuidString.prefix(8))"
        }

        let existing = try db.query("SELECT device_id FROM devices WHERE serial = ?", [.text(serialNorm)])
        if let row = existing.first, let deviceId = row["device_id"]?.intValue {
            try db.execute(
                "UPDATE devices SET vid=?, pid=?, last_seen_at=? WHERE device_id=?",
                [.text(vid), .text(pid), .text(now), .int(Int64(deviceId))]
            )
            return deviceId
        }

        try db.execute(
            "INSERT INTO devices(vid,pid,serial,first_seen_at,last_seen_at) VALUES(?,?,?,?,?)",
            [.text(vid), .text(pid), .text(serialNorm), .text(now), .text(now)]
        )
        return Int(db.lastInsertRowID)
    }

    public func device(serial: String) throws -> DeviceRecord? {
        let rows = try db.query("SELECT * FROM devices WHERE serial = ?", [.text(serial)])
        guard let row = rows.first else { return nil }
        return DeviceRecord(
            deviceId: row["device_id"]?.intValue ?? 0,
            vid: row["vid"]?.stringValue ?? "",
            pid: row["pid"]?.stringValue ?? "",
            serial: row["serial"]?.stringValue ?? "",
            firstSeenAt: row["first_seen_at"]?.stringValue ?? "",
            lastSeenAt: row["last_seen_at"]?.stringValue ?? ""
        )
    }

    // MARK: - Masters (catalog + verification upsert)

    /// Ports catalog()'s per-SKU upsert of image stats, called after
    /// MasterBuilder finishes building an image.
    public func upsertMasterCatalog(
        sku: String, imgPath: String, imageBytes: Int64, imageMib1dp: Double, usedMib1dp: Double,
        imageFileCount: Int, imageTrackCount: Int, imageIsbn: String?
    ) throws {
        let now = Self.isoNow()
        try db.execute(
            """
            INSERT INTO masters(sku,img_path,image_bytes,image_mib_1dp,used_mib_1dp,image_file_count,image_track_count,image_isbn,created_at,modified_at,updated_at)
            VALUES(?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(sku) DO UPDATE SET
              img_path=excluded.img_path, image_bytes=excluded.image_bytes, image_mib_1dp=excluded.image_mib_1dp,
              used_mib_1dp=excluded.used_mib_1dp, image_file_count=excluded.image_file_count,
              image_track_count=excluded.image_track_count, image_isbn=excluded.image_isbn,
              modified_at=excluded.modified_at, updated_at=excluded.updated_at
            """,
            [.text(sku), .text(imgPath), .int(imageBytes), .real(imageMib1dp), .real(usedMib1dp),
             .int(Int64(imageFileCount)), .int(Int64(imageTrackCount)), imageIsbn.map(DBValue.text) ?? .null,
             .text(now), .text(now), .text(now)]
        )
    }

    /// Ports verify()'s post-verification upsert into masters (serial,
    /// isbn, track_count, read_mib_s, last_stick_used_mib_1dp).
    public func recordVerification(
        sku: String, serial: String?, isbn: String?, trackCount: Int, readMibS: Double?, stickUsedMib1dp: Double?
    ) throws {
        let now = Self.isoNow()
        try db.execute(
            """
            INSERT INTO masters(sku,serial,isbn,track_count,read_mib_s,last_stick_used_mib_1dp,updated_at)
            VALUES(?,?,?,?,?,?,?)
            ON CONFLICT(sku) DO UPDATE SET
              serial=excluded.serial, isbn=excluded.isbn, track_count=excluded.track_count,
              read_mib_s=COALESCE(excluded.read_mib_s, masters.read_mib_s),
              last_stick_used_mib_1dp=excluded.last_stick_used_mib_1dp, updated_at=excluded.updated_at
            """,
            [.text(sku), serial.map(DBValue.text) ?? .null, isbn.map(DBValue.text) ?? .null,
             .int(Int64(trackCount)), readMibS.map(DBValue.real) ?? .null, stickUsedMib1dp.map(DBValue.real) ?? .null,
             .text(now)]
        )
    }

    public func master(sku: String) throws -> MasterRecord? {
        let rows = try db.query("SELECT * FROM masters WHERE sku = ?", [.text(sku)])
        return rows.first.map(MasterRecord.init)
    }

    public func allMasters() throws -> [MasterRecord] {
        try db.query("SELECT * FROM masters ORDER BY sku ASC").map(MasterRecord.init)
    }

    // MARK: - Writes

    @discardableResult
    public func insertWrite(
        sku: String, deviceId: Int, diskId: String, elapsedS: Int,
        throughputUsedMibS: Double, throughputImageMibS: Double, trackCount: Int,
        tracksPath: String?, imgPath: String
    ) throws -> Int {
        try db.execute(
            """
            INSERT INTO writes(timestamp,sku,device_id,disk_id,elapsed_s,throughput_used_mib_s,throughput_image_mib_s,track_count,tracks_path,img_path)
            VALUES(?,?,?,?,?,?,?,?,?,?)
            """,
            [.text(Self.isoNow()), .text(sku), .int(Int64(deviceId)), .text(diskId), .int(Int64(elapsedS)),
             .real(throughputUsedMibS), .real(throughputImageMibS), .int(Int64(trackCount)),
             tracksPath.map(DBValue.text) ?? .null, .text(imgPath)]
        )
        return Int(db.lastInsertRowID)
    }

    // MARK: - Duplicator runs

    @discardableResult
    public func insertDuplicatorRuns(sourceFile: String, rows: [DupeRow]) throws -> Int {
        var inserted = 0
        for r in rows {
            try db.execute(
                """
                INSERT INTO duplicator_runs(
                  source_file, run_index, dt, port, result, function_name, function_raw, time_raw,
                  data_mib, data_mib_1dp, capacity_raw, capacity_mib, sectors, speed_factor, write_speed_mib_s, read_speed_mib_s,
                  vid, pid, serial, notes, raw_line
                ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """,
                [
                    .text(sourceFile), r.runIndex.map { .int(Int64($0)) } ?? .null, r.dt.map(DBValue.text) ?? .null,
                    r.port.map(DBValue.text) ?? .null, r.result.map(DBValue.text) ?? .null,
                    r.functionName.map(DBValue.text) ?? .null, .text(r.functionRaw), r.timeRaw.map(DBValue.text) ?? .null,
                    r.dataMib.map(DBValue.real) ?? .null, r.dataMib1dp.map(DBValue.real) ?? .null,
                    r.capacityRaw.map(DBValue.text) ?? .null, r.capacityMib.map(DBValue.real) ?? .null,
                    r.sectors.map { .int(Int64($0)) } ?? .null, r.speedFactor.map(DBValue.real) ?? .null,
                    r.writeSpeedMibS.map(DBValue.real) ?? .null, r.readSpeedMibS.map(DBValue.real) ?? .null,
                    r.vid.map(DBValue.text) ?? .null, r.pid.map(DBValue.text) ?? .null,
                    .text(r.serial), .text(r.notes), .text(r.rawLine),
                ]
            )
            inserted += 1
        }
        return inserted
    }

    /// Filenames (not full paths -- robust against a sync layer like
    /// Google Drive/NAS relocating files) already ingested via any
    /// source_file recorded on a duplicator_runs row. Used by
    /// DuplicatorLogSync to skip files it's already synced rather than
    /// re-ingesting (and duplicating) every row on every scan --
    /// insertDuplicatorRuns itself has no uniqueness constraint to fall
    /// back on.
    public func syncedDuplicatorLogFileNames() throws -> Set<String> {
        let rows = try db.query("SELECT DISTINCT source_file FROM duplicator_runs WHERE source_file IS NOT NULL")
        return Set(rows.compactMap { $0["source_file"]?.stringValue }.map { URL(fileURLWithPath: $0).lastPathComponent })
    }

    public func duplicatorRuns(serial: String) throws -> [DuplicatorRunRecord] {
        try db.query("SELECT * FROM duplicator_runs WHERE serial = ? ORDER BY dt ASC", [.text(serial)])
            .map(DuplicatorRunRecord.init)
    }

    public func writes(sku: String? = nil, serial: String? = nil) throws -> [WriteRecord] {
        if let serial {
            return try db.query(
                """
                SELECT writes.* FROM writes
                JOIN devices ON devices.device_id = writes.device_id
                WHERE devices.serial = ?
                ORDER BY writes.timestamp ASC
                """,
                [.text(serial)]
            ).map(WriteRecord.init)
        }
        if let sku {
            return try db.query("SELECT * FROM writes WHERE sku = ? ORDER BY timestamp ASC", [.text(sku)])
                .map(WriteRecord.init)
        }
        return try db.query("SELECT * FROM writes ORDER BY timestamp ASC").map(WriteRecord.init)
    }

    /// "See the history of any block added to the dock": every write and
    /// every duplicator-log appearance for one specific physical device.
    public func deviceHistory(serial: String) throws -> DeviceHistory {
        DeviceHistory(
            device: try device(serial: serial),
            writes: try writes(serial: serial),
            duplicatorRuns: try duplicatorRuns(serial: serial)
        )
    }

    // MARK: - Duplicator <-> master reconciliation (ports exporter.py's export_matches/stats)

    /// Fuzzy-matches duplicator log rows to known masters by comparing
    /// copied data size (data_mib_1dp) against each master's known
    /// used_mib_1dp -- "which book was probably duplicated here, judging
    /// by how much data was written." Ambiguous when multiple masters
    /// share that size; no_match when none do.
    public func matchDuplicatorRuns() throws -> [DuplicatorMatchRecord] {
        try db.query("""
            WITH candidates AS (
              SELECT d.id AS dupe_id,
                     d.dt, d.port, d.serial, d.result, d.function_name,
                     d.data_mib_1dp, d.speed_factor, d.write_speed_mib_s, d.read_speed_mib_s,
                     m.sku AS candidate_sku
              FROM duplicator_runs d
              LEFT JOIN masters m
                ON m.used_mib_1dp = d.data_mib_1dp
            ),
            agg AS (
              SELECT dupe_id, dt, port, serial, result, function_name,
                     data_mib_1dp, speed_factor, write_speed_mib_s, read_speed_mib_s,
                     COUNT(candidate_sku) AS candidate_count,
                     GROUP_CONCAT(candidate_sku, '|') AS candidate_skus
              FROM candidates
              GROUP BY dupe_id
            )
            SELECT *,
              CASE
                WHEN candidate_count = 0 THEN 'no_match'
                WHEN candidate_count = 1 THEN 'unique'
                ELSE 'ambiguous'
              END AS match_status
            FROM agg
            ORDER BY dt ASC, dupe_id ASC
            """).map(DuplicatorMatchRecord.init)
    }

    public func stats() throws -> ProductionStats {
        let matches = try matchDuplicatorRuns()
        return ProductionStats(
            totalDuplicatorRuns: matches.count,
            uniqueMatches: matches.filter { $0.matchStatus == "unique" }.count,
            ambiguousMatches: matches.filter { $0.matchStatus == "ambiguous" }.count,
            unmatchedRuns: matches.filter { $0.matchStatus == "no_match" }.count
        )
    }

    // MARK: -

    private static func isoNow() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }
}
