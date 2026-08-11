import XCTest
@testable import BookMaster

final class CameraScannerTests: XCTestCase {
    func testPlausibleISBN13AcceptsThirteenDigits() {
        XCTAssertTrue(isPlausibleISBN13("9780134685991"))
    }

    func testPlausibleISBN13RejectsWrongLength() {
        XCTAssertFalse(isPlausibleISBN13("978013468599")) // 12 digits
        XCTAssertFalse(isPlausibleISBN13("97801346859911")) // 14 digits
    }

    func testPlausibleISBN13RejectsNonNumeric() {
        XCTAssertFalse(isPlausibleISBN13("978013468599X"))
        XCTAssertFalse(isPlausibleISBN13(""))
    }
}
