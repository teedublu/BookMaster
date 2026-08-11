import XCTest
@testable import BookMaster

/// USBSerialLookup walks the real IORegistry, so there's nothing
/// meaningful to mock -- these tests run it against whatever disks
/// actually exist on the test machine, the same way USBMonitorTests
/// (Phase 2) exercises live DiskArbitration rather than a fake.
final class USBSerialLookupTests: XCTestCase {
    func testInternalDiskHasNoUSBSerial() {
        // disk0 is the internal boot disk on every Mac this can run on --
        // walking its IORegistry parents must terminate (not hang/crash)
        // and must not fabricate a serial for a non-USB device.
        XCTAssertNil(USBSerialLookup.serialNumber(forBSDName: "disk0"))
    }

    func testNonexistentBSDNameReturnsNilRatherThanCrashing() {
        XCTAssertNil(USBSerialLookup.serialNumber(forBSDName: "disk9999"))
    }

    func testLookupCompletesQuickly() {
        // A hang here would mean the parent-walk loop failed to terminate --
        // guard the whole IORegistry round trip with a generous wall-clock
        // budget rather than asserting an exact timing.
        let start = Date()
        _ = USBSerialLookup.serialNumber(forBSDName: "disk0")
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.0)
    }
}
