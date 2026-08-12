import XCTest
@testable import BookMaster

final class MasterResolverTests: XCTestCase {
    private func makeLog() throws -> (ProductionLog, URL) {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("resolver-db-\(UUID().uuidString).db")
        let db = try AppDatabase(path: path)
        return (ProductionLog(db: db), path)
    }

    private func cleanup(_ path: URL) {
        try? FileManager.default.removeItem(at: path)
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: path.path + "-wal"))
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: path.path + "-shm"))
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: path.path + "-journal"))
    }

    func testResolvesCatalogedSKUFromDatabase() throws {
        let (log, dbPath) = try makeLog()
        defer { cleanup(dbPath) }

        let imgDir = FileManager.default.temporaryDirectory.appendingPathComponent("resolver-img-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: imgDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: imgDir) }
        let imgPath = imgDir.appendingPathComponent("BK-1.img")
        try Data(count: 1_048_576).write(to: imgPath) // 1 MiB

        try log.upsertMasterCatalog(
            sku: "BK-1", imgPath: imgPath.path, imageBytes: 1_048_576, imageMib1dp: 1.0, usedMib1dp: 0.8,
            imageFileCount: 5, imageTrackCount: 5, imageIsbn: "9781234567897"
        )

        let outputFolder = FileManager.default.temporaryDirectory.appendingPathComponent("resolver-out-\(UUID().uuidString)")
        switch MasterResolver.resolve(input: "BK-1", outputFolder: outputFolder, productionLog: log) {
        case .success(let master):
            XCTAssertEqual(master.sku, "BK-1")
            XCTAssertEqual(master.imagePath.path, imgPath.path)
            XCTAssertEqual(master.imageMib, 1.0)
            XCTAssertEqual(master.usedMib, 0.8)
        case .failure(let error):
            XCTFail("expected success, got \(error)")
        }
    }

    func testFallsBackToOutputFolderScanWhenNotCataloged() throws {
        let outputFolder = FileManager.default.temporaryDirectory.appendingPathComponent("resolver-out-\(UUID().uuidString)")
        let imageDir = outputFolder.appendingPathComponent("BK-2").appendingPathComponent("image")
        try FileManager.default.createDirectory(at: imageDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputFolder) }
        try Data(count: 2_097_152).write(to: imageDir.appendingPathComponent("BK-2.img")) // 2 MiB

        switch MasterResolver.resolve(input: "BK-2", outputFolder: outputFolder, productionLog: nil) {
        case .success(let master):
            XCTAssertEqual(master.sku, "BK-2")
            XCTAssertEqual(master.imagePath.lastPathComponent, "BK-2.img")
            XCTAssertEqual(master.imageMib, 2.0)
        case .failure(let error):
            XCTFail("expected success, got \(error)")
        }
    }

    func testTranslatesThirteenDigitISBNToCatalogSKU() {
        // BooksCatalog is loaded from the bundled books.csv resource;
        // this ISBN/SKU pair is used elsewhere in this test suite too
        // (DuplicatorLogParserTests fixtures reference the same catalog).
        let resolvedSKU = MasterResolver.resolvedSKU(fromUserInput: "9781739693695")
        XCTAssertEqual(resolvedSKU, "BK-93695-MBBP")
    }

    func testNonISBNInputIsUsedAsSKUDirectly() {
        XCTAssertEqual(MasterResolver.resolvedSKU(fromUserInput: "BK-1-XYZ"), "BK-1-XYZ")
    }

    func testReturnsNotFoundWhenNeitherSourceHasIt() {
        let outputFolder = FileManager.default.temporaryDirectory.appendingPathComponent("resolver-empty-\(UUID().uuidString)")
        switch MasterResolver.resolve(input: "NOPE-SKU", outputFolder: outputFolder, productionLog: nil) {
        case .success:
            XCTFail("expected failure for a SKU that exists nowhere")
        case .failure(let error):
            guard case .notFound = error else {
                XCTFail("expected .notFound, got \(error)")
                return
            }
        }
    }

    func testEmptyInputReturnsNotFoundRatherThanCrashing() {
        let outputFolder = FileManager.default.temporaryDirectory
        switch MasterResolver.resolve(input: "   ", outputFolder: outputFolder, productionLog: nil) {
        case .success:
            XCTFail("expected failure for blank input")
        case .failure(let error):
            guard case .notFound = error else {
                XCTFail("expected .notFound, got \(error)")
                return
            }
        }
    }
}
