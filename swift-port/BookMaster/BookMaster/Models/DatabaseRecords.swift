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
