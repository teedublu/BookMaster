import XCTest
@testable import BookMaster

final class MasterCatalogSyncTests: XCTestCase {
    private var scratchDirectories: [URL] = []

    override func tearDown() {
        for directory in scratchDirectories {
            // Built images are locked with chflags uchg (DiskImageBuilder.lockReadOnly), which blocks removal.
            try? Shell.run("/usr/bin/chflags", ["-R", "nouchg", directory.path])
            try? FileManager.default.removeItem(at: directory)
        }
        scratchDirectories = []
        super.tearDown()
    }

    private func makeScratchDirectory(_ label: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        scratchDirectories.append(directory)
        return directory
    }

    private func makeProductionLog() throws -> ProductionLog {
        let directory = try makeScratchDirectory("catalog-db")
        return ProductionLog(db: try AppDatabase(path: directory.appendingPathComponent("voxmaster.db")))
    }

    private func touch(_ root: URL, _ relativePath: String, contents: Data = Data()) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url)
    }

    private func buildMasterImage(sku: String, isbn: String, trackCount: Int, in library: URL) throws -> URL {
        let source = try makeScratchDirectory("catalog-source")
        for index in 1...trackCount {
            try touch(source, String(format: "tracks/%03d.mp3", index), contents: Data(repeating: 0xAB, count: 256 * 1024))
        }
        try touch(source, "bookInfo/id.txt", contents: Data(isbn.utf8))
        try touch(source, "bookInfo/count.txt", contents: Data(String(trackCount).utf8))
        return try DiskImageBuilder.buildImage(
            fromSourceFolder: source, volumeLabel: sku,
            outputPath: library.appendingPathComponent(sku).appendingPathComponent("image")
        ).imagePath
    }

    func testFindsMasterImagesAtAnyDepthPreferringTheImageNamedAfterItsFolder() throws {
        let library = try makeScratchDirectory("catalog-find")
        try touch(library, "2025/BK-1/image/BK-1.img")
        try touch(library, "2025/BK-1/image/MBR-BK-1.img")
        try touch(library, "BK-2/image/renamed.img")
        try touch(library, "BK-2/master/bookInfo/id.txt")
        try touch(library, "BK-3/image/a.img")
        try touch(library, "BK-3/image/b.img")
        try touch(library, "BK-4/processed/001.mp3")
        try touch(library, "Photos/image/cover.jpg")

        let found = MasterCatalogSync.findMasterImages(under: library)

        XCTAssertEqual(found.images.map(\.sku), ["BK-1", "BK-2"])
        XCTAssertEqual(found.images.map(\.path.lastPathComponent), ["BK-1.img", "renamed.img"])
        XCTAssertEqual(found.failures.map(\.sku), ["BK-3"])
        XCTAssertEqual(
            MasterCatalogSync.findMasterImages(under: library.appendingPathComponent("BK-2")).images.map(\.sku), ["BK-2"],
            "pointing straight at one master folder should find it too"
        )
    }

    func testSyncRecordsMeasuredStatsSkipsUnchangedImagesAndReportsUnreadableOnes() async throws {
        let library = try makeScratchDirectory("catalog-library")
        let log = try makeProductionLog()
        let image = try buildMasterImage(sku: "BK-11111-AB", isbn: "9781234567897", trackCount: 3, in: library)
        try touch(library, "BK-99999-ZZ/image/BK-99999-ZZ.img", contents: Data("not a disk image".utf8))

        let first = try await MasterCatalogSync.sync(root: library, productionLog: log)
        XCTAssertEqual(first.updatedSkus, ["BK-11111-AB"])
        XCTAssertEqual(first.failures.map(\.sku), ["BK-99999-ZZ"], "a bad image is reported without stopping the scan")

        let record = try XCTUnwrap(log.master(sku: "BK-11111-AB"))
        XCTAssertEqual(record.imageIsbn, "9781234567897")
        XCTAssertEqual(record.imageTrackCount, 3)
        XCTAssertEqual(record.imageFileCount, 5, "3 tracks + id.txt + count.txt")
        XCTAssertEqual(record.imageBytes, try XCTUnwrap(ImageFileIdentity(path: image)).bytes)
        let used = try XCTUnwrap(record.usedMib1dp)
        XCTAssertGreaterThanOrEqual(used, 0.7, "3 x 256 KiB of track data is on the volume")
        XCTAssertLessThan(used, try XCTUnwrap(record.imageMib1dp))

        let second = try await MasterCatalogSync.sync(root: library, productionLog: log)
        XCTAssertEqual(second.updatedSkus, [])
        XCTAssertEqual(second.skippedUnchangedCount, 1)

        let forced = try await MasterCatalogSync.sync(root: library, productionLog: log, recheckUnchanged: true)
        XCTAssertEqual(forced.updatedSkus, ["BK-11111-AB"])

        try Shell.run("/usr/bin/chflags", ["nouchg", image.path])
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: image.path)
        let afterChange = try await MasterCatalogSync.sync(root: library, productionLog: log)
        XCTAssertEqual(afterChange.updatedSkus, ["BK-11111-AB"])
    }

    func testRowWrittenByABuildIsReadEvenWhenPathSizeAndModifiedTimeMatch() async throws {
        let library = try makeScratchDirectory("catalog-built")
        let log = try makeProductionLog()
        let image = try buildMasterImage(sku: "BK-22222-CD", isbn: "9781234567897", trackCount: 1, in: library)
        let discoveredPath = try XCTUnwrap(MasterCatalogSync.findMasterImages(under: library.canonicalized()).images.first).path.path
        let identity = try XCTUnwrap(ImageFileIdentity(path: image))

        // What MasterBuilder records: an estimated used size, and created_at from the first build rather than the file.
        try log.upsertMasterCatalog(
            sku: "BK-22222-CD", imgPath: discoveredPath, imageBytes: identity.bytes, imageMib1dp: 10, usedMib1dp: 99.9,
            imageFileCount: 1, imageTrackCount: 1, imageIsbn: nil
        )
        try log.db.execute(
            "UPDATE masters SET created_at = '2020-01-01T00:00:00Z', modified_at = ? WHERE sku = 'BK-22222-CD'",
            [identity.modifiedAt.map(DBValue.text)]
        )
        let before = try XCTUnwrap(log.master(sku: "BK-22222-CD"))
        XCTAssertEqual(before.imgPath, discoveredPath)
        XCTAssertEqual(before.modifiedAt, identity.modifiedAt)

        let summary = try await MasterCatalogSync.sync(root: library, productionLog: log)

        XCTAssertEqual(summary.updatedSkus, ["BK-22222-CD"])
        XCTAssertNotEqual(try log.master(sku: "BK-22222-CD")?.usedMib1dp, 99.9)
        XCTAssertEqual(try log.master(sku: "BK-22222-CD")?.createdAt, identity.createdAt)
    }
}
