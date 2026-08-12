import XCTest
@testable import BookMaster

final class MasterWriterTests: XCTestCase {
    func testThroughputComputation() {
        XCTAssertEqual(MasterWriter.throughputMibS(mib: 100.0, elapsedSeconds: 10), 10.0)
        XCTAssertEqual(MasterWriter.throughputMibS(mib: 33.0, elapsedSeconds: 7), 4.71, accuracy: 0.01)
    }

    func testThroughputWithZeroElapsedDoesNotDivideByZero() {
        XCTAssertEqual(MasterWriter.throughputMibS(mib: 100.0, elapsedSeconds: 0), 0)
    }
}
