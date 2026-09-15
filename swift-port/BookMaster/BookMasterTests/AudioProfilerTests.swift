import XCTest
@testable import BookMaster

final class AudioProfilerTests: XCTestCase {
    func testQuickAndFullScanAgreeOnUniformTracks() async throws {
        guard let ffmpeg = FFmpegEncoder.locateFFmpeg() else { throw XCTSkip("ffmpeg not installed") }

        let fm = FileManager.default
        let tracksDir = fm.temporaryDirectory.appendingPathComponent("audioprofile-\(UUID().uuidString)")
        try fm.createDirectory(at: tracksDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tracksDir) }

        // Three 2-second 96kbps mono MP3s -- known total duration (6s) and rate (~96kbps).
        for i in 1...3 {
            let out = tracksDir.appendingPathComponent(String(format: "%03d.mp3", i))
            try Shell.run(ffmpeg, [
                "-y", "-f", "lavfi", "-i", "sine=frequency=440:duration=2",
                "-ar", "44100", "-ab", "96k", "-ac", "1", out.path,
            ])
        }

        let quick = await AudioProfiler.inspectTracksAudioProfile(tracksPath: tracksDir, fullScan: false)
        let full = await AudioProfiler.inspectTracksAudioProfile(tracksPath: tracksDir, fullScan: true)

        XCTAssertNotNil(quick.durationSeconds)
        XCTAssertNotNil(full.durationSeconds)
        // Real encoded MP3s have some framing/container overhead, so allow slack,
        // but both modes should land in the same ballpark of the true ~6s total.
        XCTAssertEqual(Double(quick.durationSeconds ?? 0), 6.0, accuracy: 2.0)
        XCTAssertEqual(Double(full.durationSeconds ?? 0), 6.0, accuracy: 2.0)
        XCTAssertEqual(full.parsedFileCount, 3)

        XCTAssertNotNil(quick.averageKbps)
        XCTAssertEqual(quick.averageKbps ?? 0, 96.0, accuracy: 20.0)
    }

    func testTagBytesOnAShortFirstTrackDoNotInflateTheRate() async throws {
        guard let ffmpeg = FFmpegEncoder.locateFFmpeg() else { throw XCTSkip("ffmpeg not installed") }

        let fm = FileManager.default
        let tracksDir = fm.temporaryDirectory.appendingPathComponent("audioprofile-tags-\(UUID().uuidString)")
        try fm.createDirectory(at: tracksDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tracksDir) }

        // A 3-second intro carrying an 8 KB ID3 comment, then a 30-second chapter, both CBR 96kbps.
        for (index, seconds, comment) in [(1, 3, String(repeating: "x", count: 8_000)), (2, 30, "")] {
            try Shell.run(ffmpeg, [
                "-y", "-f", "lavfi", "-i", "sine=frequency=440:duration=\(seconds)",
                "-ar", "44100", "-ab", "96k", "-ac", "1", "-metadata", "comment=\(comment)",
                tracksDir.appendingPathComponent(String(format: "%03d.mp3", index)).path,
            ])
        }
        let introBytes = try XCTUnwrap(fm.attributesOfItem(atPath: tracksDir.appendingPathComponent("001.mp3").path)[.size] as? Int64)
        XCTAssertGreaterThan(Double(introBytes) * 8 / 3 / 1000, 110, "whole-file size / duration reads far above 96kbps for this intro")

        let quick = await AudioProfiler.inspectTracksAudioProfile(tracksPath: tracksDir, fullScan: false)
        let full = await AudioProfiler.inspectTracksAudioProfile(tracksPath: tracksDir, fullScan: true)

        XCTAssertEqual(try XCTUnwrap(quick.averageKbps), 96.0, accuracy: 0.05)
        XCTAssertEqual(try XCTUnwrap(full.averageKbps), 96.0, accuracy: 0.05)
        XCTAssertEqual(full.parsedFileCount, 2)
    }

    func testEmptyFolderReturnsNilProfile() async throws {
        let fm = FileManager.default
        let emptyDir = fm.temporaryDirectory.appendingPathComponent("audioprofile-empty-\(UUID().uuidString)")
        try fm.createDirectory(at: emptyDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: emptyDir) }

        let result = await AudioProfiler.inspectTracksAudioProfile(tracksPath: emptyDir, fullScan: true)
        XCTAssertNil(result.durationSeconds)
        XCTAssertEqual(result.parsedFileCount, 0)
    }

    func testMeasureTrackAudioBytesFallsBackToAllFilesWhenNoneMatchKnownExtensions() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("audioprofile-fallback-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        try "data".write(to: dir.appendingPathComponent("track.xyz"), atomically: true, encoding: .utf8)
        let (bytes, count) = AudioProfiler.measureTrackAudioBytes(tracksPath: dir)
        XCTAssertEqual(count, 1)
        XCTAssertGreaterThan(bytes, 0)
    }
}
