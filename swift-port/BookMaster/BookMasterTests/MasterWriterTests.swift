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

    // MARK: - Finding the written block's mount point

    func testMountPointIsParsedFromDiskutilInfo() {
        let info = """
           Device Identifier:         disk7s1
           Volume Name:               VOXBLOCK
           Mounted:                   Yes
           Mount Point:               /Volumes/VOXBLOCK 1
           File System Personality:   MS-DOS FAT32
        """
        XCTAssertEqual(Shell.mountPoint(fromDiskutilInfo: info), "/Volumes/VOXBLOCK 1")
    }

    func testNoMountPointIsReportedForAnUnmountedOrFilesystemlessDisk() {
        XCTAssertNil(Shell.mountPoint(fromDiskutilInfo: "   Mounted:                   No\n   Mount Point:               \n"))
        XCTAssertNil(Shell.mountPoint(fromDiskutilInfo: "   Mount Point:"), "the label alone is not a path")
        XCTAssertNil(Shell.mountPoint(fromDiskutilInfo: "   Mount Point:               Not applicable (no file system)\n"))
        XCTAssertNil(Shell.mountPoint(fromDiskutilInfo: ""))
    }

    /// Why the writer asks the disk for its mount point instead of building `/Volumes/<label>`: two blocks
    /// with the same label (every MYO block is VOXBLOCK) mount as `VOXBLOCK` and `VOXBLOCK 1`, so a path
    /// built from the label can only ever be the first one, whichever drive was just written.
    func testMountPointIsTheDisksOwnWhenAnotherVolumeSharesItsLabel() throws {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("mw-mount-\(UUID().uuidString)")
        let source = scratch.appendingPathComponent("source")
        try fm.createDirectory(at: source.appendingPathComponent("tracks"), withIntermediateDirectories: true)
        try "chapter".write(to: source.appendingPathComponent("tracks/001.mp3"), atomically: true, encoding: .utf8)
        // Registered first so it runs last, after the images are detached (teardown blocks run in reverse).
        addTeardownBlock {
            try? Shell.run("/usr/bin/chflags", ["-R", "nouchg", scratch.path])
            try? fm.removeItem(at: scratch)
        }

        // One image of each layout, both labelled VOXBLOCK: bare FAT (the whole disk is the volume) and
        // MBR (the volume is slice 1).
        let bareFAT = try DiskImageBuilder.buildImage(
            fromSourceFolder: source, volumeLabel: "BK-11111-AAAA",
            outputPath: scratch.appendingPathComponent("a"), fatLabel: "VOXBLOCK"
        ).imagePath
        let mbr = try MBRImageBuilder.buildImage(
            fromSourceFolder: source, volumeLabel: "BK-22222-BBBB",
            outputPath: scratch.appendingPathComponent("b"), fatLabel: "VOXBLOCK"
        ).imagePath

        var attached: [(bsdName: String, mountPath: String)] = []
        for image in [bareFAT, mbr] {
            let output = try Shell.run("/usr/bin/hdiutil", [
                "attach", "-imagekey", "diskimage-class=CRawDiskImage", "-readonly", "-nobrowse", image.path,
            ])
            let device = try XCTUnwrap(Shell.devicePath(fromAttachOutput: output))
            addTeardownBlock { try? Shell.run("/usr/bin/hdiutil", ["detach", device]) }
            let mountPath = try XCTUnwrap(Shell.mountPath(fromAttachOutput: output))
            attached.append((String(device.dropFirst("/dev/".count)), mountPath))
        }

        XCTAssertNotEqual(attached[0].mountPath, attached[1].mountPath, "the second VOXBLOCK should mount under a different name")
        for disk in attached {
            XCTAssertEqual(MasterWriter.mountPoint(ofBSDName: disk.bsdName)?.path, disk.mountPath, disk.bsdName)
        }
    }
}
