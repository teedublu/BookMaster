import XCTest
@testable import BookMaster

/// Hits the real BookData Sanity API (public, read-only, no token) --
/// confirmed live during development that this dataset's `book` document
/// type is a red herring (isbn/coverImage fields exist in the schema but
/// are almost entirely unpopulated); the Shopify-synced productVariant/
/// product documents are what's actually populated, joined by SKU. These
/// tests skip rather than fail if the network/API is unreachable, the
/// same pattern FFmpegEncoderTests uses for a missing external tool.
final class BookCoverLookupTests: XCTestCase {
    /// A SKU confirmed (during development, live) to resolve to a real
    /// Shopify CDN image URL via this lookup.
    private let knownSKU = "BK-93695-MBBP"

    private func requireNetwork() async throws {
        guard (try? await URLSession.shared.data(from: URL(string: "https://h2okhvxc.api.sanity.io/v2023-02-07/data/query/production?query=1")!)) != nil else {
            throw XCTSkip("Sanity API unreachable from this environment")
        }
    }

    func testKnownSKUResolvesToAShopifyCDNImageURL() async throws {
        try await requireNetwork()
        let url = await BookCoverLookup.coverImageURL(forSKU: knownSKU)
        XCTAssertNotNil(url)
        XCTAssertEqual(url?.host, "cdn.shopify.com")
    }

    func testUnknownSKUReturnsNilRatherThanThrowing() async throws {
        try await requireNetwork()
        let url = await BookCoverLookup.coverImageURL(forSKU: "NOT-A-REAL-SKU-\(UUID().uuidString)")
        XCTAssertNil(url)
    }

    func testEmptySKUReturnsNilWithoutMakingARequest() async {
        let url = await BookCoverLookup.coverImageURL(forSKU: "")
        XCTAssertNil(url)
    }
}
