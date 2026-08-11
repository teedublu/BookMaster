import Foundation

/// One parsed row from a USB duplicator device's log file. Ported from
/// duplicator.py's DupeRow dataclass; the parser that produces these
/// (DuplicatorLogParser.swift) is Phase 13 -- this type is defined
/// early since ProductionLog's insertDuplicatorRuns already needs it.
public struct DupeRow: Equatable {
    public let runIndex: Int?
    public let dt: String?
    public let port: String?
    public let result: String?
    public let functionRaw: String
    public let functionName: String?
    public let timeRaw: String?
    public let capacityRaw: String?
    public let capacityMib: Double?
    public let sectors: Int?
    public let dataMib: Double?
    public let dataMib1dp: Double?
    public let speedFactor: Double?
    public let writeSpeedMibS: Double?
    public let readSpeedMibS: Double?
    public let vid: String?
    public let pid: String?
    public let serial: String
    public let notes: String
    public let rawLine: String

    public init(
        runIndex: Int?, dt: String?, port: String?, result: String?, functionRaw: String, functionName: String?,
        timeRaw: String?, capacityRaw: String?, capacityMib: Double?, sectors: Int?, dataMib: Double?, dataMib1dp: Double?,
        speedFactor: Double?, writeSpeedMibS: Double?, readSpeedMibS: Double?, vid: String?, pid: String?,
        serial: String, notes: String, rawLine: String
    ) {
        self.runIndex = runIndex
        self.dt = dt
        self.port = port
        self.result = result
        self.functionRaw = functionRaw
        self.functionName = functionName
        self.timeRaw = timeRaw
        self.capacityRaw = capacityRaw
        self.capacityMib = capacityMib
        self.sectors = sectors
        self.dataMib = dataMib
        self.dataMib1dp = dataMib1dp
        self.speedFactor = speedFactor
        self.writeSpeedMibS = writeSpeedMibS
        self.readSpeedMibS = readSpeedMibS
        self.vid = vid
        self.pid = pid
        self.serial = serial
        self.notes = notes
        self.rawLine = rawLine
    }
}
