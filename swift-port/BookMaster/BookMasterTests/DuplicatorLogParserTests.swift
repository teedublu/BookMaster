import XCTest
@testable import BookMaster

final class DuplicatorLogParserTests: XCTestCase {

    /// Builds one fixed-column log line by writing each field at its
    /// exact character offset -- the same (start, end) pairs
    /// DuplicatorLogParser's columnSpecs uses -- rather than guessing at
    /// widths and separators (only 3 of the 9 field boundaries actually
    /// have a 1-space gap; the rest are contiguous, easy to get subtly
    /// wrong by hand).
    private func buildLine(
        index: String, datetime: String, port: String, result: String,
        function: String, time: String, capacity: String, vid: String, pid: String, serial: String
    ) -> String {
        let specs: [(Int, Int)] = [(0, 7), (8, 27), (28, 34), (35, 51), (51, 90), (90, 105), (105, 125), (125, 131), (131, 137)]
        let values = [index, datetime, port, result, function, time, capacity, vid, pid]

        let totalLen = max(specs.last!.1, 137 + serial.count)
        var chars = [Character](repeating: " ", count: totalLen)
        for (spec, value) in zip(specs, values) {
            for (offset, ch) in value.prefix(spec.1 - spec.0).enumerated() {
                chars[spec.0 + offset] = ch
            }
        }
        for (offset, ch) in serial.enumerated() {
            chars[137 + offset] = ch
        }
        return String(chars)
    }

    func testParsesFullyWellFormedCopyLine() {
        let line = buildLine(
            index: "0000001", datetime: "2026-01-01 10:00:00", port: "01", result: "PASS",
            function: "COPY DATA,980.5MB R:25.3M/S", time: "0:39", capacity: "1.9GB(4014080)",
            vid: "0781", pid: "5567", serial: "[1234567890123] Real Size=980MB"
        )
        let rows = DuplicatorLogParser.parse(line)
        XCTAssertEqual(rows.count, 1)
        let row = rows[0]

        XCTAssertEqual(row.runIndex, 1)
        XCTAssertEqual(row.dt, "2026-01-01 10:00:00")
        XCTAssertEqual(row.port, "01")
        XCTAssertEqual(row.result, "PASS")
        XCTAssertEqual(row.functionName, "COPY")
        XCTAssertEqual(row.dataMib, 980.5)
        XCTAssertEqual(row.dataMib1dp, 980.5)
        XCTAssertEqual(row.readSpeedMibS, 25.3)
        XCTAssertEqual(row.timeRaw, "0:39")
        XCTAssertEqual(row.sectors, 4014080)
        XCTAssertEqual(row.capacityMib ?? 0, 4014080.0 / 2048.0, accuracy: 0.01)
        XCTAssertEqual(row.vid, "0781")
        XCTAssertEqual(row.pid, "5567")
        XCTAssertEqual(row.serial, "1234567890123")

        // COPY is both a "copy/compare" function and specifically "copy",
        // so both speed_factor and write_speed_mib_s should be populated,
        // derived from data_mib / elapsed_seconds (980.5 / 39s).
        XCTAssertEqual(row.speedFactor ?? 0, 980.5 / 39.0, accuracy: 0.01)
        XCTAssertEqual(row.writeSpeedMibS, row.speedFactor)
    }

    func testCompareFunctionGetsSpeedFactorButNotWriteSpeed() {
        let line = buildLine(
            index: "0000002", datetime: "2026-01-01 10:01:00", port: "02", result: "PASS",
            function: "COMPARE DATA,500.0MB", time: "1:00", capacity: "1.9GB(4014080)",
            vid: "0781", pid: "5567", serial: "[9999999999999]"
        )
        let row = DuplicatorLogParser.parse(line)[0]
        XCTAssertEqual(row.functionName, "COMPARE")
        XCTAssertNotNil(row.speedFactor, "COMPARE contains 'comp' -> counts as a copy/compare function")
        XCTAssertNil(row.writeSpeedMibS, "write_speed is copy-only, COMPARE must not get it")
    }

    func testNonCopyCompareFunctionGetsNoSpeedFactorAtAll() {
        let line = buildLine(
            index: "0000003", datetime: "2026-01-01 10:02:00", port: "03", result: "SKIP",
            function: "ERASE", time: "0:10", capacity: "1.9GB(4014080)",
            vid: "0781", pid: "5567", serial: "[1111111111111]"
        )
        let row = DuplicatorLogParser.parse(line)[0]
        XCTAssertEqual(row.functionName, "ERASE")
        XCTAssertNil(row.speedFactor)
        XCTAssertNil(row.writeSpeedMibS)
    }

    func testUnreadableSerialBecomesUnknownWithNotes() {
        let line = buildLine(
            index: "0000004", datetime: "2026-01-01 10:03:00", port: "04", result: "FAIL",
            function: "COPY DATA,10.0MB", time: "0:05", capacity: "1.9GB(4014080)",
            vid: "0781", pid: "5567", serial: "[N/A] Real Size=Unknown"
        )
        let row = DuplicatorLogParser.parse(line)[0]
        XCTAssertEqual(row.serial, "UNKNOWN")
        XCTAssertFalse(row.notes.isEmpty)
    }

    func testIgnoresLinesNotStartingWithSevenDigits() {
        let text = """
        Header text, not a data row
        0000001 2026-01-01 10:00:00 01    PASS            COPY DATA,10.0MB
        Some footer summary line
        """
        let rows = DuplicatorLogParser.parse(text)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].runIndex, 1)
    }

    func testParseElapsedSecondsHandlesBothMMSSAndHHMMSS() {
        XCTAssertEqual(DuplicatorLogParser.parseElapsedSeconds("1:30"), 90)
        XCTAssertEqual(DuplicatorLogParser.parseElapsedSeconds("1:02:03"), 3723)
        XCTAssertNil(DuplicatorLogParser.parseElapsedSeconds(nil))
        XCTAssertNil(DuplicatorLogParser.parseElapsedSeconds(""))
    }

    func testCapacityUsesSectorsAsSourceOfTruthNotTheLabel() {
        // The device's own "1.9GB" label is a decimal approximation;
        // the real value should come from sectors (512-byte) / 2048.
        let (mib, sectors) = DuplicatorLogParser.extractCapacity("1.9GB(4014080)")
        XCTAssertEqual(sectors, 4014080)
        XCTAssertEqual(mib ?? 0, 4014080.0 / 2048.0, accuracy: 0.01)
    }

    func testParseLogFileEndToEnd() throws {
        let fm = FileManager.default
        let logFile = fm.temporaryDirectory.appendingPathComponent("dupe-\(UUID().uuidString).log")
        defer { try? fm.removeItem(at: logFile) }

        let line1 = buildLine(index: "0000001", datetime: "2026-01-01 10:00:00", port: "01", result: "PASS", function: "COPY DATA,100.0MB", time: "0:10", capacity: "1.9GB(4014080)", vid: "0781", pid: "5567", serial: "[1111111111111]")
        let line2 = buildLine(index: "0000002", datetime: "2026-01-01 10:01:00", port: "02", result: "PASS", function: "COPY DATA,200.0MB", time: "0:20", capacity: "1.9GB(4014080)", vid: "0781", pid: "5567", serial: "[2222222222222]")
        try (line1 + "\n" + line2 + "\n").write(to: logFile, atomically: true, encoding: .utf8)

        let rows = try DuplicatorLogParser.parseLog(at: logFile)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].serial, "1111111111111")
        XCTAssertEqual(rows[1].serial, "2222222222222")
    }
}
