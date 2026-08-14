import XCTest
@testable import BookMaster

/// Real coverage starts in Phase 8 — this just proves the test target
/// is wired up correctly so Phase 3+ work can add tests incrementally
/// rather than in one big batch at the end.
final class PlaceholderTests: XCTestCase {
    func testTestTargetIsWired() {
        XCTAssertEqual(AppSettings().cacheFiles, false)
    }
}
