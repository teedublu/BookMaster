import Foundation

/// Ports duplicator.py's fixed-column USB duplicator log parser exactly
/// -- same column offsets, same regexes, same speed-factor/write-speed
/// derivation rules. These logs come from a physical hardware USB
/// duplicator (a machine that clones one master onto many blank drives
/// at once); this parser is what makes `ingest-dupe` possible.
public enum DuplicatorLogParser {
    // (start, end) character offsets, matching Python's [s:e] slicing exactly.
    private static let columnSpecs: [(Int, Int)] = [
        (0, 7),     // Index
        (8, 27),    // Datetime
        (28, 34),   // Port
        (35, 51),   // Result
        (51, 90),   // Function
        (90, 105),  // Time
        (105, 125), // CapacityRaw
        (125, 131), // VID
        (131, 137), // PID
        (137, 999), // SerialRaw
    ]

    public static func parseLog(at path: URL) throws -> [DupeRow] {
        let text = try String(contentsOf: path, encoding: .utf8)
        return parse(text)
    }

    public static func parse(_ text: String) -> [DupeRow] {
        // Swift's Character is a grapheme cluster, and "\r\n" composes
        // into a single one -- splitting on a bare "\n" Character never
        // matches it, so a CRLF-terminated file (what these
        // machine-generated logs actually export, near-universally)
        // would collapse into a handful of giant multi-line blobs with
        // zero recognizable data lines instead of one row per line. See
        // the identical fix in BooksCatalog.swift's CSVParser.
        let text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var rows: [DupeRow] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            guard lineStartsWithSevenDigits(line) else { continue }
            if let row = parseLine(String(line)) {
                rows.append(row)
            }
        }
        return rows
    }

    // MARK: - Per-line parsing

    private static func parseLine(_ line: String) -> DupeRow? {
        let chars = Array(line)
        func field(_ range: (Int, Int)) -> String {
            let start = min(range.0, chars.count)
            let end = min(range.1, chars.count)
            guard start < end else { return "" }
            return String(chars[start..<end]).trimmingCharacters(in: .whitespaces)
        }

        let idxS = field(columnSpecs[0])
        let dtS = field(columnSpecs[1])
        let port = field(columnSpecs[2])
        let result = field(columnSpecs[3])
        let funcRaw = field(columnSpecs[4])
        let timeS = field(columnSpecs[5])
        let capRaw = field(columnSpecs[6])
        let vid = field(columnSpecs[7])
        let pid = field(columnSpecs[8])
        let serialRaw = field(columnSpecs[9])

        let runIndex = Int(idxS)
        let dtISO = parseDatetime(dtS)

        let (functionName, dataMib) = extractFunctionData(funcRaw)
        let dataMib1dp = dataMib.map { ($0 * 10).rounded() / 10 }

        let (capMib, sectors) = extractCapacity(capRaw)
        let readSpeed = extractReadSpeed(funcRaw)

        var speedFactor: Double?
        if isCopyCompareFunction(functionName) {
            speedFactor = computeSpeedFactor(dataMib: dataMib, timeRaw: timeS.isEmpty ? nil : timeS)
        }
        let writeSpeed = isCopyOnlyFunction(functionName) ? speedFactor : nil

        let (serial, notes) = normalizeSerial(serialRaw)

        return DupeRow(
            runIndex: runIndex, dt: dtISO, port: port.isEmpty ? nil : port, result: result.isEmpty ? nil : result,
            functionRaw: funcRaw, functionName: functionName, timeRaw: timeS.isEmpty ? nil : timeS,
            capacityRaw: capRaw.isEmpty ? nil : capRaw, capacityMib: capMib, sectors: sectors,
            dataMib: dataMib, dataMib1dp: dataMib1dp, speedFactor: speedFactor, writeSpeedMibS: writeSpeed,
            readSpeedMibS: readSpeed, vid: vid.isEmpty ? nil : vid, pid: pid.isEmpty ? nil : pid,
            serial: serial, notes: notes, rawLine: line
        )
    }

    // MARK: - Field extraction (ports the individual util functions)

    private static func lineStartsWithSevenDigits(_ line: Substring) -> Bool {
        guard line.count >= 7 else { return false }
        return line.prefix(7).allSatisfy(\.isNumber)
    }

    static func parseDatetime(_ s: String) -> String? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if let date = formatter.date(from: trimmed) {
            let iso = DateFormatter()
            iso.dateFormat = "yyyy-MM-dd HH:mm:ss"
            iso.timeZone = TimeZone(identifier: "UTC")
            iso.locale = Locale(identifier: "en_US_POSIX")
            return iso.string(from: date)
        }
        return trimmed
    }

    static func extractFunctionData(_ functionStr: String) -> (name: String?, dataMib: Double?) {
        let trimmed = functionStr.trimmingCharacters(in: .whitespaces)
        // Python uses re.match (anchored at the start); NSRegularExpression's
        // search is unanchored by default, so this needs an explicit ^.
        let name = firstMatch(pattern: #"^([\w\+]+)"#, in: trimmed)
        let dataMibStr = firstMatch(pattern: #"DATA,(\d+\.?\d*)MB"#, in: functionStr, group: 1)
        return (name, dataMibStr.flatMap(Double.init))
    }

    static func extractCapacity(_ capStr: String) -> (mib: Double?, sectors: Int?) {
        let trimmed = capStr.trimmingCharacters(in: .whitespaces)
        guard let sectorsStr = firstMatch(pattern: #"^(\d+\.?\d*)([MG]B)\((\d+)\)"#, in: trimmed, group: 3),
              let sectors = Int(sectorsStr) else {
            return (nil, nil)
        }
        // 1 MiB = 2048 sectors of 512 bytes -- sectors are the source of
        // truth, not the device's own "MB"/"GB" label (which is
        // frequently a marketing/decimal approximation).
        let mib = (Double(sectors) / 2048.0 * 10).rounded() / 10
        return (mib, sectors)
    }

    static func extractReadSpeed(_ functionStr: String) -> Double? {
        firstMatch(pattern: #"R:(\d+\.?\d*)M/S"#, in: functionStr, group: 1).flatMap(Double.init)
    }

    static func parseElapsedSeconds(_ timeRaw: String?) -> Int? {
        guard let timeRaw, !timeRaw.isEmpty else { return nil }
        let parts = timeRaw.trimmingCharacters(in: .whitespaces).split(separator: ":").map(String.init)
        if parts.count == 2, let mm = Int(parts[0]), let ss = Int(parts[1]) {
            return mm * 60 + ss
        }
        if parts.count == 3, let hh = Int(parts[0]), let mm = Int(parts[1]), let ss = Int(parts[2]) {
            return hh * 3600 + mm * 60 + ss
        }
        return nil
    }

    static func computeSpeedFactor(dataMib: Double?, timeRaw: String?) -> Double? {
        guard let dataMib else { return nil }
        guard let secs = parseElapsedSeconds(timeRaw), secs > 0 else { return nil }
        return (dataMib / Double(secs) * 100).rounded() / 100
    }

    static func isCopyCompareFunction(_ functionName: String?) -> Bool {
        let n = (functionName ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        return n.contains("copy") || n.contains("comp")
    }

    static func isCopyOnlyFunction(_ functionName: String?) -> Bool {
        (functionName ?? "").trimmingCharacters(in: .whitespaces).lowercased() == "copy"
    }

    static func normalizeSerial(_ serialRaw: String) -> (serial: String, notes: String) {
        let bracketed = firstMatch(pattern: #"\[([^\]]*)\]"#, in: serialRaw, group: 1)
        let noteMatch = firstMatch(pattern: #"Real Size=.*"#, in: serialRaw)

        let raw = bracketed?.trimmingCharacters(in: .whitespaces) ?? ""
        let note = noteMatch ?? ""

        if !raw.isEmpty, raw.allSatisfy(\.isNumber) {
            return (raw, note)
        }
        return ("UNKNOWN", note.isEmpty ? raw : note)
    }

    // MARK: - Regex helper

    private static func firstMatch(pattern: String, in text: String, group: Int = 0) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > group else { return nil }
        guard let r = Range(match.range(at: group), in: text) else { return nil }
        return String(text[r])
    }
}
