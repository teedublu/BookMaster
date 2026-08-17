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

    // MARK: - Master builds (file side: what a build produced)

    @discardableResult
    public func insertMasterBuild(
        sku: String, isbn: String?, imgPath: String, imageBytes: Int64?, imageMib1dp: Double?,
        usedMib1dp: Double?, fileCount: Int?, trackCount: Int?, checksum: String?, status: String = "success"
    ) throws -> Int {
        try db.execute(
            """
            INSERT INTO master_builds(sku,isbn,built_at,img_path,image_bytes,image_mib_1dp,used_mib_1dp,file_count,track_count,checksum,status)
            VALUES(?,?,?,?,?,?,?,?,?,?,?)
            """,
            [.text(sku), isbn.map(DBValue.text) ?? .null, .text(Self.isoNow()), .text(imgPath),
             imageBytes.map(DBValue.int) ?? .null, imageMib1dp.map(DBValue.real) ?? .null,
             usedMib1dp.map(DBValue.real) ?? .null, fileCount.map { .int(Int64($0)) } ?? .null,
             trackCount.map { .int(Int64($0)) } ?? .null, checksum.map(DBValue.text) ?? .null, .text(status)]
        )
        return Int(db.lastInsertRowID)
    }

    public func latestMasterBuild(sku: String) throws -> MasterBuildRecord? {
        try db.query("SELECT * FROM master_builds WHERE sku = ? ORDER BY built_at DESC, id DESC LIMIT 1", [.text(sku)])
            .first.map(MasterBuildRecord.init)
    }

    public func masterBuilds(sku: String) throws -> [MasterBuildRecord] {
        try db.query("SELECT * FROM master_builds WHERE sku = ? ORDER BY built_at DESC, id DESC", [.text(sku)])
            .map(MasterBuildRecord.init)
    }

    // MARK: - Master checks (content-completeness QA against a build)

    @discardableResult
    public func insertMasterCheck(
        buildId: Int, checkType: String, expectedValue: String?, actualValue: String?, passed: Bool, message: String?
    ) throws -> Int {
        try db.execute(
            """
            INSERT INTO master_checks(build_id,check_type,expected_value,actual_value,passed,message,checked_at)
            VALUES(?,?,?,?,?,?,?)
            """,
            [.int(Int64(buildId)), .text(checkType), expectedValue.map(DBValue.text) ?? .null,
             actualValue.map(DBValue.text) ?? .null, .int(passed ? 1 : 0), message.map(DBValue.text) ?? .null,
             .text(Self.isoNow())]
        )
        return Int(db.lastInsertRowID)
    }

    public func masterChecks(buildId: Int) throws -> [MasterCheckRecord] {
        try db.query("SELECT * FROM master_checks WHERE build_id = ? ORDER BY checked_at ASC", [.int(Int64(buildId))])
            .map(MasterCheckRecord.init)
    }

    // MARK: - Master writes (block side: writing a build onto a physical block)

    @discardableResult
    public func insertMasterWrite(
        deviceId: Int, masterBuildId: Int?, sku: String, elapsedS: Int,
        throughputImageMibS: Double, throughputUsedMibS: Double, trackCountWritten: Int,
        foundArtifactCount: Int, removedArtifactCount: Int, diskId: String?
    ) throws -> Int {
        try db.execute(
            """
            INSERT INTO master_writes(device_id,master_build_id,sku,written_at,elapsed_s,throughput_image_mib_s,throughput_used_mib_s,track_count_written,found_artifact_count,removed_artifact_count,disk_id)
            VALUES(?,?,?,?,?,?,?,?,?,?,?)
            """,
            [.int(Int64(deviceId)), masterBuildId.map { .int(Int64($0)) } ?? .null, .text(sku), .text(Self.isoNow()),
             .int(Int64(elapsedS)), .real(throughputImageMibS), .real(throughputUsedMibS),
             .int(Int64(trackCountWritten)), .int(Int64(foundArtifactCount)), .int(Int64(removedArtifactCount)),
             diskId.map(DBValue.text) ?? .null]
        )
        return Int(db.lastInsertRowID)
    }

    public func masterWrites(deviceId: Int) throws -> [MasterWriteRecord] {
        try db.query("SELECT * FROM master_writes WHERE device_id = ? ORDER BY written_at ASC", [.int(Int64(deviceId))])
            .map(MasterWriteRecord.init)
    }

    // MARK: - Master verifications (block side: is this block accurate)

    @discardableResult
    public func insertMasterVerification(
        deviceId: Int?, masterWriteId: Int?, sku: String?, detectedSku: String?, detectedIsbn: String?,
        trackCount: Int, stickUsedMib: Double?, tracksSizeMib: Double?, readSpeedMibS: Double?,
        expectedDurationS: Int?, encodingKbps: Double?, encodingRateAnomaly: Bool,
        foundArtifactCount: Int, id3IssueCount: Int, validationErrors: [String], passed: Bool
    ) throws -> Int {
        try db.execute(
            """
            INSERT INTO master_verifications(
              device_id, master_write_id, sku, detected_sku, detected_isbn, track_count, stick_used_mib, tracks_size_mib,
              read_speed_mib_s, expected_duration_s, encoding_kbps, encoding_rate_anomaly, found_artifact_count,
              id3_issue_count, validation_errors, passed, verified_at
            ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """,
            [
                deviceId.map { .int(Int64($0)) } ?? .null, masterWriteId.map { .int(Int64($0)) } ?? .null,
                sku.map(DBValue.text) ?? .null, detectedSku.map(DBValue.text) ?? .null, detectedIsbn.map(DBValue.text) ?? .null,
                .int(Int64(trackCount)), stickUsedMib.map(DBValue.real) ?? .null, tracksSizeMib.map(DBValue.real) ?? .null,
                readSpeedMibS.map(DBValue.real) ?? .null, expectedDurationS.map { .int(Int64($0)) } ?? .null,
                encodingKbps.map(DBValue.real) ?? .null, .int(encodingRateAnomaly ? 1 : 0), .int(Int64(foundArtifactCount)),
                .int(Int64(id3IssueCount)), validationErrors.isEmpty ? .null : .text(validationErrors.joined(separator: "; ")),
                .int(passed ? 1 : 0), .text(Self.isoNow()),
            ]
        )
        return Int(db.lastInsertRowID)
    }

    public func masterVerifications(deviceId: Int) throws -> [MasterVerificationRecord] {
        try db.query("SELECT * FROM master_verifications WHERE device_id = ? ORDER BY verified_at ASC", [.int(Int64(deviceId))])
            .map(MasterVerificationRecord.init)
    }

    /// "Is this master block accurate": every write and every
    /// verification this exact physical block has received.
    public func masterBlockHistory(serial: String) throws -> MasterBlockHistory {
        guard let dev = try device(serial: serial) else {
            return MasterBlockHistory(device: nil, writes: [], verifications: [])
        }
        return MasterBlockHistory(
            device: dev,
            writes: try masterWrites(deviceId: dev.deviceId),
            verifications: try masterVerifications(deviceId: dev.deviceId)
        )
    }

    // MARK: -

    private static func isoNow() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }
}
