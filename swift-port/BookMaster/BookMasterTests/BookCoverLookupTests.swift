import XCTest
@testable import BookMaster

/// BookCoverCatalog is a bundled, static lookup (see book_covers.csv) --
/// no network involved, unlike the Sanity-backed BookCoverLookup this
/// replaced, so these run fully offline and deterministically.
final class BookCoverLookupTests: XCTestCase {
    /// A SKU confirmed present in book_covers.csv (see the generator
    /// script's output) -- "A Bear Called Paddington".
    private let knownSKU = "BK-93695-MBBP"

    func testKnownSKUResolvesToAShopifyCDNImageURL() {
        let url = BookCoverCatalog.coverImageURL(forSKU: knownSKU)
        XCTAssertNotNil(url)
        XCTAssertEqual(url?.host, "cdn.shopify.com")
    }

    func testUnknownSKUReturnsNil() {
        let url = BookCoverCatalog.coverImageURL(forSKU: "NOT-A-REAL-SKU-\(UUID().uuidString)")
        XCTAssertNil(url)
    }

    func testEmptySKUReturnsNil() {
        let url = BookCoverCatalog.coverImageURL(forSKU: "")
        XCTAssertNil(url)
    }
}
