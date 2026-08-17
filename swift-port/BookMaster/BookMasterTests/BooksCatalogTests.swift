import XCTest
@testable import BookMaster

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

    func testFileCountReadsFromFilesColumn() {
        // books.csv's file-count column is named "Files", not
        // "ExpectedFileCount" (the key main_window.py read, which always
        // fell back to 0 since no such column exists) -- ContentView's
        // ISBN lookup reads "Files" instead so File Count actually
        // populates alongside Title/Author.
        let row = BooksCatalog.lookup(isbn: "9781917979276")
        XCTAssertEqual(row?["Files"], "5")
        XCTAssertNil(row?["ExpectedFileCount"])
    }

    func testCSVParserHandlesQuotedFieldsWithEmbeddedCommas() {
        let csv = "ISBN,Title,Notes\n123,\"Hello, World\",\"She said \"\"hi\"\"\"\n"
        let parsed = BooksCatalog.parse(csv)
        XCTAssertEqual(parsed["123"]?["Title"], "Hello, World")
        XCTAssertEqual(parsed["123"]?["Notes"], "She said \"hi\"")
    }
}
