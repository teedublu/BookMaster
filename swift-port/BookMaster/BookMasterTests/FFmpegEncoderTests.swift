import XCTest
import AVFoundation
@testable import BookMaster

/// Exercises the real ffmpeg pipeline end-to-end: generates a synthetic
/// test tone (no real book audio needed), reads its duration natively,
/// encodes it through the exact same filter graph track.py uses, and
/// verifies the output is a valid, correctly-encoded MP3. Skips itself
/// if ffmpeg isn't installed on the machine running the tests.
final class FFmpegEncoderTests: XCTestCase {
    func testEncodeProducesValidMP3WithExpectedProperties() async throws {
        guard let ffmpeg = FFmpegEncoder.locateFFmpeg() else {
            throw XCTSkip("ffmpeg not installed on this machine")
        }

        let fm = FileManager.default
        let workDir = fm.temporaryDirectory.appendingPathComponent("ffmpeg-test-\(UUID().uuidString)")
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workDir) }

        let inputPath = workDir.appendingPathComponent("tone.wav")
        let outputPath = workDir.appendingPathComponent("encoded.mp3")

        // Generate a real 2-second 440Hz test tone -- no book audio needed.
        try Shell.run(ffmpeg, ["-y", "-f", "lavfi", "-i", "sine=frequency=440:duration=2", inputPath.path])

        let duration = try await AudioDuration.seconds(ofFileAt: inputPath)
        XCTAssertEqual(duration, 2.0, accuracy: 0.1)

        let params = EncodeParameters(sampleRate: 44100, bitRate: 96000, targetLufs: -19, durationSeconds: duration)
        _ = try FFmpegEncoder.encode(inputPath: inputPath, outputPath: outputPath, parameters: params)

        XCTAssertTrue(fm.fileExists(atPath: outputPath.path))

        let outputAsset = AVURLAsset(url: outputPath)
        let outputDuration = try await outputAsset.load(.duration)
        let outputSeconds = CMTimeGetSeconds(outputDuration)
        // amix with duration=first should keep it close to the source length.
        XCTAssertEqual(outputSeconds, duration, accuracy: 0.5)

        let tracks = try await outputAsset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(tracks.count, 1, "expected exactly one mono audio track")
    }

    func testEncodeWithoutStripMetadataLeavesFFmpegsDefaultTag() async throws {
        guard let ffmpeg = FFmpegEncoder.locateFFmpeg() else {
            throw XCTSkip("ffmpeg not installed on this machine")
        }
        let fm = FileManager.default
        let workDir = fm.temporaryDirectory.appendingPathComponent("ffmpeg-tag-\(UUID().uuidString)")
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workDir) }

        let inputPath = workDir.appendingPathComponent("tone.wav")
        let outputPath = workDir.appendingPathComponent("encoded.mp3")
        try Shell.run(ffmpeg, ["-y", "-f", "lavfi", "-i", "sine=frequency=440:duration=1", inputPath.path])

        let duration = try await AudioDuration.seconds(ofFileAt: inputPath)
        let params = EncodeParameters(sampleRate: 44100, bitRate: 96000, targetLufs: -19, durationSeconds: duration)
        _ = try FFmpegEncoder.encode(inputPath: inputPath, outputPath: outputPath, parameters: params)

        XCTAssertTrue(ID3Tag.hasID3v2Header(at: outputPath), "ffmpeg's mp3 muxer writes its own ID3v2 tag unless -id3v2_version 0 is passed")
    }

    func testEncodeWithStripMetadataProducesUntaggedOutput() async throws {
        guard let ffmpeg = FFmpegEncoder.locateFFmpeg() else {
            throw XCTSkip("ffmpeg not installed on this machine")
        }
        let fm = FileManager.default
        let workDir = fm.temporaryDirectory.appendingPathComponent("ffmpeg-strip-\(UUID().uuidString)")
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workDir) }

        let inputPath = workDir.appendingPathComponent("tone.wav")
        let outputPath = workDir.appendingPathComponent("encoded.mp3")
        try Shell.run(ffmpeg, ["-y", "-f", "lavfi", "-i", "sine=frequency=440:duration=1", inputPath.path])

        let duration = try await AudioDuration.seconds(ofFileAt: inputPath)
        let params = EncodeParameters(sampleRate: 44100, bitRate: 96000, targetLufs: -19, durationSeconds: duration, stripMetadata: true)
        _ = try FFmpegEncoder.encode(inputPath: inputPath, outputPath: outputPath, parameters: params)

        XCTAssertFalse(ID3Tag.hasID3v2Header(at: outputPath))
        XCTAssertFalse(ID3Tag.hasID3v1Trailer(at: outputPath))
        XCTAssertEqual(ID3Tag.readID3v2Frames(at: outputPath), [])
    }

    func testEncodeThrowsWithInvalidFFmpegPath() async throws {
        let params = EncodeParameters(sampleRate: 44100, bitRate: 96000, targetLufs: -19, durationSeconds: 1)
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID().uuidString).wav")
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("out-\(UUID().uuidString).mp3")
        do {
            _ = try FFmpegEncoder.encode(inputPath: missing, outputPath: out, parameters: params, ffmpegPath: "/nonexistent/ffmpeg")
            XCTFail("expected an error for a nonexistent ffmpeg binary")
        } catch {
            // any thrown error is acceptable here -- proving it doesn't
            // silently "succeed" with a missing binary/input is the point.
        }
    }
}
