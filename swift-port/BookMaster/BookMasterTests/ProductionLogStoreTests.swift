import XCTest
@testable import BookMaster

@MainActor
final class ProductionLogStoreTests: XCTestCase {
    func testOpenSucceedsAndSkipsRedundantReopenOfSamePath() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ProductionLogStore()

        store.open(inDirectory: dir)
        XCTAssertNotNil(store.log)
        XCTAssertNil(store.lastError)
        let firstLog = store.log

        // Reopening the same resolved path must not tear down and
        // recreate the connection -- ContentView calls open() on every
        // .onAppear/.onChange firing, not just when the path actually
        // changes, so this is what keeps a mounted network share from
        // being hit on every unrelated settings change.
        store.open(inDirectory: dir)
        XCTAssertIdentical(firstLog, store.log)
    }

    func testOpenAgainstDifferentDirectorySwitchesConnection() {
        let dirA = FileManager.default.temporaryDirectory.appendingPathComponent("store-a-\(UUID().uuidString)")
        let dirB = FileManager.default.temporaryDirectory.appendingPathComponent("store-b-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: dirA)
            try? FileManager.default.removeItem(at: dirB)
        }
        let store = ProductionLogStore()

        store.open(inDirectory: dirA)
        let logA = store.log
        XCTAssertEqual(store.currentPath, dirA.appendingPathComponent("voxmaster.db"))

        store.open(inDirectory: dirB)
        XCTAssertNotIdentical(logA, store.log)
        XCTAssertEqual(store.currentPath, dirB.appendingPathComponent("voxmaster.db"))
    }

    func testOpenAgainstUnwritableDirectoryRecordsErrorInsteadOfCrashing() {
        // /dev/null/nope is neither a directory nor creatable -- exercises
        // the failure path (surfaced in the UI as a red warning + log
        // line) without needing a real unmounted network share.
        let store = ProductionLogStore()
        store.open(inDirectory: URL(fileURLWithPath: "/dev/null/nope"))
        XCTAssertNil(store.log)
        XCTAssertNotNil(store.lastError)
    }
}
