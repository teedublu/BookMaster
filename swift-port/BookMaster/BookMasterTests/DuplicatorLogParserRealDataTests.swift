import XCTest
@testable import BookMaster

/// Regression coverage using lines copied verbatim (byte-for-byte,
/// including control characters) from a real duplicator machine's log
/// export (~/duplicator-logs/example-logs.txt, not bundled with the
/// app -- reference material only), rather than only the synthetic
/// fixtures DuplicatorLogParserTests builds by hand. Cross-checked the
/// column layout against that folder's log-usb-parser.py (the original
/// reference this was ported from) and found it matches exactly; these
/// tests exist to catch real-world shapes a hand-built fixture wouldn't
/// think to cover.
final class DuplicatorLogParserRealDataTests: XCTestCase {
    func testRealCopyLineWithHexVIDSuffixParsesCorrectly() {
        let line = "0001209 2025-04-29 11:00:35  0006  PASS            COPY(DATA,136.2MB)                     00:29          960.0MB(1966080)    ABCDh 1234h [2409111742002042285509]"
        let row = DuplicatorLogParser.parse(line)[0]
        XCTAssertEqual(row.result, "PASS")
        XCTAssertEqual(row.functionName, "COPY")
        XCTAssertEqual(row.dataMib, 136.2)
        // The real machine output embeds a trailing "h" (hex marker)
        // directly in the fixed-width VID/PID columns with no
        // separating space -- log-usb-parser.py doesn't strip it either,
        // so neither does this: vid/pid are stored exactly as printed.
        XCTAssertEqual(row.vid, "ABCDh")
        XCTAssertEqual(row.pid, "1234h")
        XCTAssertEqual(row.serial, "2409111742002042285509")
    }

    func testRealFailedTestLineWithEmptyBracketsAndZeroVID() {
        let line = "0001479 2025-05-01 14:51:19  0003  FAIL(LBA:0)     H5 TEST(100%) W:  R:                   00:00           (0)                0000h 0000h []"
        let row = DuplicatorLogParser.parse(line)[0]
        // Result carries its full parenthesized detail, not just a bare
        // PASS/FAIL token.
        XCTAssertEqual(row.result, "FAIL(LBA:0)")
        XCTAssertEqual(row.functionName, "H5")
        XCTAssertEqual(row.vid, "0000h")
        XCTAssertEqual(row.serial, "UNKNOWN")
    }

    func testRealLineWithGarbledControlCharacterSerialNormalizesToUnknown() {
        // The real machine occasionally emits genuine junk in the serial
        // field -- a tab followed by a control byte, not digits -- and
        // this must still normalize to UNKNOWN rather than crash or
        // propagate an unprintable value.
        let line = "0001565 2025-05-02 11:58:09  0005  FAIL(LBA:0)     COPY+COMP(T)                           00:00           (1)                1E3Dh 198Ah [\t\u{04}]"
        let row = DuplicatorLogParser.parse(line)[0]
        // The `+` must survive extraction (Python's [\w\+]+ ports to the
        // same character class) -- "COPY+COMP", not truncated at "COPY".
        XCTAssertEqual(row.functionName, "COPY+COMP")
        XCTAssertEqual(row.serial, "UNKNOWN")
        XCTAssertTrue(DuplicatorLogParser.isCopyCompareFunction(row.functionName))
        XCTAssertFalse(DuplicatorLogParser.isCopyOnlyFunction(row.functionName), "COPY+COMP is not exactly \"copy\"")
    }

    func testRealUserAbortLineIsNotMistakenForPassOrFail() {
        let line = "0001598 2025-05-02 12:33:59  0002  User Abort      H5 TEST(100%) W:0.00M/S R:0.00M/S      00:00          960.0MB(1966080)    ABCDh 1234h [2409111742002042285509]"
        let row = DuplicatorLogParser.parse(line)[0]
        XCTAssertEqual(row.result, "User Abort")
        XCTAssertEqual(row.readSpeedMibS, 0.00)
    }

    // MARK: - Full-file real exports (jan-sep16.txt / example-logs.txt,
    // dropped at the repo root as reference material -- not bundled).
    // Running the parser against ~19k lines of real output (not just
    // hand-picked single lines) is what caught the CRLF bug below.

    /// The real machine's export is CRLF-terminated almost throughout
    /// (confirmed against jan-sep16.txt: 12985/12989 newlines are
    /// "\r\n"). Swift's Character is a grapheme cluster, and "\r\n"
    /// composes into a single one that matches neither the bare "\r"
    /// nor "\n" cases a naive `split(separator: "\n")` would look for --
    /// every prior test here embeds a single line with no line-ending
    /// character at all, so none of them could have caught a whole real
    /// export collapsing into one unparseable blob instead of one row
    /// per line.
    func testParsesMultipleCRLFTerminatedLinesNotJustOneGiantBlob() {
        let text = "0000472 2025-04-07 20:40:18  0006  PASS            COPY+COMPARE(DATA,3331.8MB)            08:08          29.2GB(61440000)    1F75h 0918h [98633223]\r\n"
            + "0000473 2025-04-07 20:40:18  0011  PASS            COPY+COMPARE(DATA,3331.8MB)            07:50          14.8GB(31129600)    1F75h 0917h [236933577249741]\r\n"
        let rows = DuplicatorLogParser.parse(text)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].runIndex, 472)
        XCTAssertEqual(rows[1].runIndex, 473)
        XCTAssertEqual(rows[1].serial, "236933577249741")
    }

    /// jan-sep16.txt's capacities run from ~960MB sticks up to 29.2GB
    /// ones -- confirms the "GB" branch (not just "MB") of the capacity
    /// regex, converted via sectors (the source of truth) rather than
    /// the device's own decimal-MB/GB label.
    func testRealLineWithGigabyteCapacityParsesSectorsCorrectly() {
        let line = "0000472 2025-04-07 20:40:18  0006  PASS            COPY+COMPARE(DATA,3331.8MB)            08:08          29.2GB(61440000)    1F75h 0918h [98633223]"
        let row = DuplicatorLogParser.parse(line)[0]
        XCTAssertEqual(row.sectors, 61440000)
        XCTAssertEqual(row.capacityMib, 30000.0)
    }

    /// The same real export also has plenty of lowercased "Copy"/
    /// "Copy+Compare" alongside the more common all-caps "COPY" --
    /// isCopyCompareFunction/isCopyOnlyFunction lowercase before
    /// comparing, so this should classify identically either way.
    func testRealLineWithLowercaseFunctionNameStillClassifiesAsCopyCompare() {
        let line = "0000555 2025-04-23 21:42:45  0016  PASS            Copy+Compare(DATA,152.5MB)             00:27          980.0MB(2007040)    ABCDh 1234h [20230718]"
        let row = DuplicatorLogParser.parse(line)[0]
        XCTAssertEqual(row.functionName, "Copy+Compare")
        XCTAssertTrue(DuplicatorLogParser.isCopyCompareFunction(row.functionName))
        XCTAssertFalse(DuplicatorLogParser.isCopyOnlyFunction(row.functionName))
    }
}
