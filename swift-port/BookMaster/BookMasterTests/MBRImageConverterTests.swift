import XCTest
@testable import BookMaster

final class MBRImageConverterTests: XCTestCase {
    private var scratchDirectories: [URL] = []

    override func tearDown() {
        for directory in scratchDirectories {
            // Superfloppy images are locked with chflags uchg (DiskImageBuilder.lockReadOnly), which blocks removal.
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

    private func write(_ root: URL, _ relativePath: String, _ contents: Data) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url)
    }

    private func track(_ index: Int) -> Data { Data(repeating: UInt8(index), count: 256 * 1024) }

    /// A real superfloppy master image at `<library>/<sku>/image/<sku>.img`, as DiskImageBuilder publishes it.
    private func buildSuperfloppyMaster(sku: String, isbn: String, trackCount: Int, in library: URL) throws -> URL {
        let source = try makeScratchDirectory("convert-source")
        for index in 1...trackCount {
            try write(source, String(format: "tracks/%03d.mp3", index), track(index))
        }
        try write(source, "bookInfo/id.txt", Data(isbn.utf8))
        try write(source, "bookInfo/count.txt", Data(String(trackCount).utf8))
        return try DiskImageBuilder.buildImage(
            fromSourceFolder: source, volumeLabel: sku,
            outputPath: library.appendingPathComponent(sku).appendingPathComponent("image")
        ).imagePath
    }

    func testOutputNameIsTheSourceNameWithTheMBRPrefixBesideIt() {
        let source = URL(fileURLWithPath: "/masters/BK-1/image/BK-1.img")
        XCTAssertEqual(MBRImageConverter.outputURL(forSource: source).path, "/masters/BK-1/image/MBR-BK-1.img")
        XCTAssertEqual(
            MBRImageConverter.outputURL(forSource: URL(fileURLWithPath: "/masters/BK-2/image/renamed.img")).lastPathComponent,
            "MBR-renamed.img"
        )
    }

    func testConvertRebuildsASuperfloppyImageAsMBRKeepingLabelAndContents() throws {
        let library = try makeScratchDirectory("convert-library")
        let sku = "BK-12345-TEST"
        let source = try buildSuperfloppyMaster(sku: sku, isbn: "9781234567897", trackCount: 2, in: library)
        let sourceLayout = try ImageLayoutInspector.inspect(source)
        XCTAssertEqual(sourceLayout.kind, .superfloppyFat)
        let sourceAttributes = try FileManager.default.attributesOfItem(atPath: source.path)

        let result = try MBRImageConverter.convert(sourceImage: source)

        XCTAssertEqual(result.imagePath, source.deletingLastPathComponent().appendingPathComponent("MBR-\(sku).img"))
        let layout = try ImageLayoutInspector.inspect(result.imagePath)
        XCTAssertEqual(layout.kind, .mbrFat)
        XCTAssertEqual(layout.fatVariant, "FAT32")
        XCTAssertEqual(layout.volumeLabel, sourceLayout.volumeLabel, "the FAT label is carried over exactly")

        try MasterContentAuditor.withMountedImage(result.imagePath) { root in
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("tracks/001.mp3")), track(1))
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("tracks/002.mp3")), track(2))
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("bookInfo/id.txt")), "9781234567897")
        }

        // The original is untouched.
        XCTAssertEqual(try ImageLayoutInspector.inspect(source).kind, .superfloppyFat)
        let afterAttributes = try FileManager.default.attributesOfItem(atPath: source.path)
        XCTAssertEqual(afterAttributes[.size] as? Int64, sourceAttributes[.size] as? Int64)
        XCTAssertEqual(afterAttributes[.modificationDate] as? Date, sourceAttributes[.modificationDate] as? Date)

        // Converting again is refused rather than overwriting, and an MBR image is not a valid source.
        XCTAssertThrowsError(try MBRImageConverter.convert(sourceImage: source)) { error in
            guard case MBRImageError.destinationExists = error else { return XCTFail("expected destinationExists, got \(error)") }
        }
        XCTAssertThrowsError(try MBRImageConverter.convert(sourceImage: result.imagePath)) { error in
            guard case MBRImageError.notSuperfloppy = error else { return XCTFail("expected notSuperfloppy, got \(error)") }
        }
    }

    func testConvertAllConvertsOnlySuperfloppyImagesAndMakesTheNewImageTheCataloguedOne() async throws {
        let library = try makeScratchDirectory("convert-all")
        let databaseFolder = try makeScratchDirectory("convert-db")
        let log = ProductionLog(db: try AppDatabase(path: databaseFolder.appendingPathComponent("voxmaster.db")))

        let toConvert = try buildSuperfloppyMaster(sku: "BK-11111-AB", isbn: "9781234567897", trackCount: 3, in: library)

        let first = try await MBRImageConverter.convertAll(under: library, productionLog: log)

        let converted = toConvert.deletingLastPathComponent().appendingPathComponent("MBR-BK-11111-AB.img")
        XCTAssertEqual(first.converted, [MBRConvertedImage(sku: "BK-11111-AB", imagePath: converted.canonicalized())])
        XCTAssertTrue(first.failures.isEmpty, "\(first.failures)")
        XCTAssertEqual(try ImageLayoutInspector.inspect(converted).kind, .mbrFat)

        let record = try XCTUnwrap(log.master(sku: "BK-11111-AB"))
        XCTAssertEqual(URL(fileURLWithPath: try XCTUnwrap(record.imgPath)).lastPathComponent, "MBR-BK-11111-AB.img")
        XCTAssertEqual(record.imageTrackCount, 3)
        XCTAssertEqual(record.imageIsbn, "9781234567897")

        // A pre-prefix MBR master (<sku>.img that is already MBR) is left alone.
        let alreadyMBR = library.appendingPathComponent("BK-22222-CD/image/BK-22222-CD.img")
        try FileManager.default.createDirectory(at: alreadyMBR.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: converted, to: alreadyMBR)

        let second = try await MBRImageConverter.convertAll(under: library, productionLog: log)

        XCTAssertTrue(second.converted.isEmpty)
        XCTAssertTrue(second.failures.isEmpty, "\(second.failures)")
        XCTAssertEqual(second.skipped.map(\.sku).sorted(), ["BK-11111-AB", "BK-22222-CD"])
        XCTAssertTrue(second.skipped.contains { $0.message == "BK-22222-CD.img is already MBR" })
        XCTAssertTrue(second.skipped.contains { $0.message == "MBR-BK-11111-AB.img already exists" })
    }
}
