import XCTest
@testable import BookMaster

final class BitrateFittingTests: XCTestCase {
    func testFitsUnchangedWhenWellUnderCapacity() {
        let result = BitrateFitting.fitBitRate(
            currentSizeBytes: 100_000_000, currentBitRate: 96000, maxDriveSizeBytes: 980_000_000
        )
        XCTAssertEqual(result, 96000)
    }

    func testReducesBitRateWhenOverUsableCapacity() {
        // 980MB drive, 10% margin -> 882MB usable. 1000MB of tracks needs reducing.
        let result = BitrateFitting.fitBitRate(
            currentSizeBytes: 1_000_000_000, currentBitRate: 96000, maxDriveSizeBytes: 980_000_000
        )
        XCTAssertLessThan(result, 96000)
        XCTAssertGreaterThanOrEqual(result, BitrateFitting.minimumBitRate)
    }

    func testNeverGoesBelowMinimumBitRate() {
        let result = BitrateFitting.fitBitRate(
            currentSizeBytes: 100_000_000_000, currentBitRate: 96000, maxDriveSizeBytes: 480_000_000
        )
        XCTAssertEqual(result, BitrateFitting.minimumBitRate)
    }

    func testNeverIncreasesBitRateEvenIfPlentyOfRoom() {
        let result = BitrateFitting.fitBitRate(
            currentSizeBytes: 1, currentBitRate: 96000, maxDriveSizeBytes: 980_000_000
        )
        XCTAssertEqual(result, 96000)
    }
}
