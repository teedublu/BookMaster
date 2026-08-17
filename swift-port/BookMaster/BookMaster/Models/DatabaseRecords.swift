import Foundation

public struct DeviceRecord: Equatable {
    public let deviceId: Int
    public let vid: String
    public let pid: String
    public let serial: String
    public let firstSeenAt: String
    public let lastSeenAt: String
}

public struct MasterRecord: Equatable {
    public var sku: String
    public var imgPath: String?
    public var imageBytes: Int64?
    public var imageMib1dp: Double?
    public var usedMib1dp: Double?
    public var imageFileCount: Int?
    public var imageTrackCount: Int?
    public var imageIsbn: String?
    public var createdAt: String?
    public var modifiedAt: String?
    public var serial: String?
    public var isbn: String?
    public var trackCount: Int?
    public var readMibS: Double?
    public var lastStickUsedMib1dp: Double?
    public var updatedAt: String

    init(row: DBRow) {
        sku = row["sku"]?.stringValue ?? ""
        imgPath = row["img_path"]?.stringValue
        imageBytes = row["image_bytes"]?.int64Value
        imageMib1dp = row["image_mib_1dp"]?.doubleValue
        usedMib1dp = row["used_mib_1dp"]?.doubleValue
        imageFileCount = row["image_file_count"]?.intValue
        imageTrackCount = row["image_track_count"]?.intValue
        imageIsbn = row["image_isbn"]?.stringValue
        createdAt = row["created_at"]?.stringValue
        modifiedAt = row["modified_at"]?.stringValue
        serial = row["serial"]?.stringValue
        isbn = row["isbn"]?.stringValue
        trackCount = row["track_count"]?.intValue
        readMibS = row["read_mib_s"]?.doubleValue
        lastStickUsedMib1dp = row["last_stick_used_mib_1dp"]?.doubleValue
        updatedAt = row["updated_at"]?.stringValue ?? ""
    }
}

public struct WriteRecord: Equatable {
    public let writeId: Int
    public let timestamp: String
    public let sku: String
    public let deviceId: Int
    public let diskId: String
    public let elapsedS: Int
    public let throughputUsedMibS: Double
    public let throughputImageMibS: Double
    public let trackCount: Int
    public let tracksPath: String?
    public let imgPath: String

    init(row: DBRow) {
        writeId = row["write_id"]?.intValue ?? 0
        timestamp = row["timestamp"]?.stringValue ?? ""
        sku = row["sku"]?.stringValue ?? ""
        deviceId = row["device_id"]?.intValue ?? 0
        diskId = row["disk_id"]?.stringValue ?? ""
        elapsedS = row["elapsed_s"]?.intValue ?? 0
        throughputUsedMibS = row["throughput_used_mib_s"]?.doubleValue ?? 0
        throughputImageMibS = row["throughput_image_mib_s"]?.doubleValue ?? 0
        trackCount = row["track_count"]?.intValue ?? 0
        tracksPath = row["tracks_path"]?.stringValue
        imgPath = row["img_path"]?.stringValue ?? ""
    }
}

public struct DuplicatorRunRecord: Equatable {
    public let id: Int
    public let sourceFile: String?
    public let runIndex: Int?
    public let dt: String?
    public let port: String?
    public let result: String?
    public let functionName: String?
    public let functionRaw: String?
    public let timeRaw: String?
    public let dataMib: Double?
    public let dataMib1dp: Double?
    public let capacityRaw: String?
    public let capacityMib: Double?
    public let sectors: Int?
    public let speedFactor: Double?
    public let writeSpeedMibS: Double?
    public let readSpeedMibS: Double?
    public let vid: String?
    public let pid: String?
    public let serial: String?
    public let notes: String?
    public let rawLine: String?

    init(row: DBRow) {
        id = row["id"]?.intValue ?? 0
        sourceFile = row["source_file"]?.stringValue
        runIndex = row["run_index"]?.intValue
        dt = row["dt"]?.stringValue
        port = row["port"]?.stringValue
        result = row["result"]?.stringValue
        functionName = row["function_name"]?.stringValue
        functionRaw = row["function_raw"]?.stringValue
        timeRaw = row["time_raw"]?.stringValue
        dataMib = row["data_mib"]?.doubleValue
        dataMib1dp = row["data_mib_1dp"]?.doubleValue
        capacityRaw = row["capacity_raw"]?.stringValue
        capacityMib = row["capacity_mib"]?.doubleValue
        sectors = row["sectors"]?.intValue
        speedFactor = row["speed_factor"]?.doubleValue
        writeSpeedMibS = row["write_speed_mib_s"]?.doubleValue
        readSpeedMibS = row["read_speed_mib_s"]?.doubleValue
        vid = row["vid"]?.stringValue
        pid = row["pid"]?.stringValue
        serial = row["serial"]?.stringValue
        notes = row["notes"]?.stringValue
        rawLine = row["raw_line"]?.stringValue
    }
}

public struct DuplicatorMatchRecord: Equatable, Identifiable {
    public var id: Int { dupeId }
    public let dupeId: Int
    public let dt: String?
    public let port: String?
    public let serial: String?
    public let result: String?
    public let functionName: String?
    public let dataMib1dp: Double?
    public let speedFactor: Double?
    public let writeSpeedMibS: Double?
    public let readSpeedMibS: Double?
    public let candidateCount: Int
    public let candidateSkus: [String]
    public let matchStatus: String

    init(row: DBRow) {
        dupeId = row["dupe_id"]?.intValue ?? 0
        dt = row["dt"]?.stringValue
        port = row["port"]?.stringValue
        serial = row["serial"]?.stringValue
        result = row["result"]?.stringValue
        functionName = row["function_name"]?.stringValue
        dataMib1dp = row["data_mib_1dp"]?.doubleValue
        speedFactor = row["speed_factor"]?.doubleValue
        writeSpeedMibS = row["write_speed_mib_s"]?.doubleValue
        readSpeedMibS = row["read_speed_mib_s"]?.doubleValue
        candidateCount = row["candidate_count"]?.intValue ?? 0
        candidateSkus = (row["candidate_skus"]?.stringValue ?? "").split(separator: "|").map(String.init)
        matchStatus = row["match_status"]?.stringValue ?? "no_match"
    }
}

public struct ProductionStats: Equatable {
    public let totalDuplicatorRuns: Int
    public let uniqueMatches: Int
    public let ambiguousMatches: Int
    public let unmatchedRuns: Int
}

/// A specific physical device's production history -- what "see the
/// history of any block added to the dock" resolves to: every write this
/// exact serial has received, and every duplicator-log row it appears in.
public struct DeviceHistory: Equatable {
    public let device: DeviceRecord?
    public let writes: [WriteRecord]
    public let duplicatorRuns: [DuplicatorRunRecord]

    public var isEmpty: Bool { writes.isEmpty && duplicatorRuns.isEmpty }
}

// MARK: - Master-block lineage (file side: what a build produced; block
// side: was a specific physical master block written accurately)

/// One row per build attempt of a SKU's master image -- append-only,
/// unlike the flat `masters` table's upsert-in-place, so a regression
/// between builds is visible instead of silently overwritten.
public struct MasterBuildRecord: Equatable, Identifiable {
    public var id: Int { buildId }
    public let buildId: Int
    public let sku: String
    public let isbn: String?
    public let builtAt: String
    public let imgPath: String
    public let imageBytes: Int64?
    public let imageMib1dp: Double?
    public let usedMib1dp: Double?
    public let fileCount: Int?
    public let trackCount: Int?
    public let checksum: String?
    public let status: String

    init(row: DBRow) {
        buildId = row["id"]?.intValue ?? 0
        sku = row["sku"]?.stringValue ?? ""
        isbn = row["isbn"]?.stringValue
        builtAt = row["built_at"]?.stringValue ?? ""
        imgPath = row["img_path"]?.stringValue ?? ""
        imageBytes = row["image_bytes"]?.int64Value
        imageMib1dp = row["image_mib_1dp"]?.doubleValue
        usedMib1dp = row["used_mib_1dp"]?.doubleValue
        fileCount = row["file_count"]?.intValue
        trackCount = row["track_count"]?.intValue
        checksum = row["checksum"]?.stringValue
        status = row["status"]?.stringValue ?? ""
    }
}

/// One row per content-completeness check run against a build (see
/// MasterContentAuditor) -- row-per-check rather than fixed columns, so a
/// new check type is an insert, not a schema migration.
public struct MasterCheckRecord: Equatable, Identifiable {
    public var id: Int { checkId }
    public let checkId: Int
    public let buildId: Int
    public let checkType: String
    public let expectedValue: String?
    public let actualValue: String?
    public let passed: Bool
    public let message: String?
    public let checkedAt: String

    init(row: DBRow) {
        checkId = row["id"]?.intValue ?? 0
        buildId = row["build_id"]?.intValue ?? 0
        checkType = row["check_type"]?.stringValue ?? ""
        expectedValue = row["expected_value"]?.stringValue
        actualValue = row["actual_value"]?.stringValue
        passed = (row["passed"]?.intValue ?? 0) != 0
        message = row["message"]?.stringValue
        checkedAt = row["checked_at"]?.stringValue ?? ""
    }
}

/// One row per event of writing a master build onto a specific physical
/// block (MasterWriter). Distinct from `writes` -- this links to the
/// exact `master_builds` row that went onto the block, not just a SKU.
public struct MasterWriteRecord: Equatable, Identifiable {
    public var id: Int { writeId }
    public let writeId: Int
    public let deviceId: Int
    public let masterBuildId: Int?
    public let sku: String
    public let writtenAt: String
    public let elapsedS: Int
    public let throughputImageMibS: Double
    public let throughputUsedMibS: Double
    public let trackCountWritten: Int
    public let foundArtifactCount: Int
    public let removedArtifactCount: Int
    public let diskId: String?

    init(row: DBRow) {
        writeId = row["id"]?.intValue ?? 0
        deviceId = row["device_id"]?.intValue ?? 0
        masterBuildId = row["master_build_id"]?.intValue
        sku = row["sku"]?.stringValue ?? ""
        writtenAt = row["written_at"]?.stringValue ?? ""
        elapsedS = row["elapsed_s"]?.intValue ?? 0
        throughputImageMibS = row["throughput_image_mib_s"]?.doubleValue ?? 0
        throughputUsedMibS = row["throughput_used_mib_s"]?.doubleValue ?? 0
        trackCountWritten = row["track_count_written"]?.intValue ?? 0
        foundArtifactCount = row["found_artifact_count"]?.intValue ?? 0
        removedArtifactCount = row["removed_artifact_count"]?.intValue ?? 0
        diskId = row["disk_id"]?.stringValue
    }
}

/// One row per verification pass (DriveVerifier.verify) against a
/// physical master block's current content -- independent of a write, so
/// a block can be re-checked later without a fresh write. `passed`
/// mirrors VerificationResult.isValid; unlike the flat `masters` table's
/// recordVerification (which only fires on success), this is inserted
/// unconditionally so failed verifications -- the actually-interesting
/// case for "is this master block accurate" -- aren't lost.
public struct MasterVerificationRecord: Equatable, Identifiable {
    public var id: Int { verificationId }
    public let verificationId: Int
    public let deviceId: Int?
    public let masterWriteId: Int?
    public let sku: String?
    public let detectedSku: String?
    public let detectedIsbn: String?
    public let trackCount: Int
    public let stickUsedMib: Double?
    public let tracksSizeMib: Double?
    public let readSpeedMibS: Double?
    public let expectedDurationS: Int?
    public let encodingKbps: Double?
    public let encodingRateAnomaly: Bool
    public let foundArtifactCount: Int
    public let id3IssueCount: Int
    public let validationErrors: String?
    public let passed: Bool
    public let verifiedAt: String

    init(row: DBRow) {
        verificationId = row["id"]?.intValue ?? 0
        deviceId = row["device_id"]?.intValue
        masterWriteId = row["master_write_id"]?.intValue
        sku = row["sku"]?.stringValue
        detectedSku = row["detected_sku"]?.stringValue
        detectedIsbn = row["detected_isbn"]?.stringValue
        trackCount = row["track_count"]?.intValue ?? 0
        stickUsedMib = row["stick_used_mib"]?.doubleValue
        tracksSizeMib = row["tracks_size_mib"]?.doubleValue
        readSpeedMibS = row["read_speed_mib_s"]?.doubleValue
        expectedDurationS = row["expected_duration_s"]?.intValue
        encodingKbps = row["encoding_kbps"]?.doubleValue
        encodingRateAnomaly = (row["encoding_rate_anomaly"]?.intValue ?? 0) != 0
        foundArtifactCount = row["found_artifact_count"]?.intValue ?? 0
        id3IssueCount = row["id3_issue_count"]?.intValue ?? 0
        validationErrors = row["validation_errors"]?.stringValue
        passed = (row["passed"]?.intValue ?? 0) != 0
        verifiedAt = row["verified_at"]?.stringValue ?? ""
    }
}

/// A specific physical master block's write/verify history -- "is this
/// block an accurate copy of the master." `isAccurate` reads the most
/// recent verification only: an old pass doesn't vouch for content
/// that's since been rewritten or degraded.
public struct MasterBlockHistory: Equatable {
    public let device: DeviceRecord?
    public let writes: [MasterWriteRecord]
    public let verifications: [MasterVerificationRecord]

    public var isEmpty: Bool { writes.isEmpty && verifications.isEmpty }
    public var isAccurate: Bool? { verifications.last?.passed }
}
