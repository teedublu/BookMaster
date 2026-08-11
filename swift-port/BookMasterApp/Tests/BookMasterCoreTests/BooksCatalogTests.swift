import XCTest
@testable import BookMasterCore

final class BooksCatalogTests: XCTestCase {
    func testLoadsBundledCatalogAndLooksUpByISBN() {
        // From the real books.csv snapshot bundled at Phase 7 scaffolding time.
        let row = BooksCatalog.lookup(isbn: "9781917174060")
        XCTAssertNotNil(row)
        XCTAssertEqual(row?["SKU"], "BK-74060-JMBS")
        XCTAssertEqual(row?["Title"], "A Bad Spell for the Worst Witch")
        XCTAssertEqual(row?["Author"], "Jill Murphy")
    }

    func testLookupMissesReturnNil() {
        XCTAssertNil(BooksCatalog.lookup(isbn: "0000000000000"))
    }

    func testExpectedFileCountColumnDoesNotExist() {
        // Documents the existing Python behavior faithfully reproduced:
        // main_window.py reads row.get('ExpectedFileCount', 0), which
        // always falls back to 0 because books.csv has no such column.
        let row = BooksCatalog.lookup(isbn: "9781917174060")
        XCTAssertNil(row?["ExpectedFileCount"])
    }

    func testCSVParserHandlesQuotedFieldsWithEmbeddedCommas() {
        let csv = "ISBN,Title,Notes\n123,\"Hello, World\",\"She said \"\"hi\"\"\"\n"
        let parsed = BooksCatalog.parse(csv)
        XCTAssertEqual(parsed["123"]?["Title"], "Hello, World")
        XCTAssertEqual(parsed["123"]?["Notes"], "She said \"hi\"")
    }
}
