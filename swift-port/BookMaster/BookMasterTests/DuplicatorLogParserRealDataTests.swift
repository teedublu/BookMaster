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
}
