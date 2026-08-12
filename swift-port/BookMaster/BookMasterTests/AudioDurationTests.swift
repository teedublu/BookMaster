import XCTest
@testable import BookMaster

final class AudioDurationTests: XCTestCase {
    func testReadsRealDurationFromAnEncodedFile() async throws {
        guard let ffmpeg = FFmpegEncoder.locateFFmpeg() else { throw XCTSkip("ffmpeg not installed") }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("duration-\(UUID().uuidString).mp3")
        defer { try? FileManager.default.removeItem(at: file) }
        try Shell.run(ffmpeg, ["-y", "-f", "lavfi", "-i", "sine=frequency=440:duration=2", "-ab", "96k", file.path])

        let seconds = try await AudioDuration.seconds(ofFileAt: file)
        XCTAssertEqual(seconds, 2.0, accuracy: 0.5)
    }

    /// The exact real-world failure this guards against: a Google
    /// Drive-mounted input file that reports its correct final size but
    /// whose content is entirely zero bytes because Drive's local client
    /// hasn't actually streamed the real content in yet. Confirmed by
    /// hand against a real file in production before writing this fix.
    func testAllZeroContentIsDiagnosedAsUnsyncedPlaceholderNotGenericUnreadable() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("placeholder-\(UUID().uuidString).mp3")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(count: 6_500_760).write(to: file)

        do {
            _ = try await AudioDuration.seconds(ofFileAt: file)
            XCTFail("expected an error for an all-zero-content file")
        } catch let error as AudioDurationError {
            guard case .looksLikeUnsyncedPlaceholder = error else {
                XCTFail("expected .looksLikeUnsyncedPlaceholder, got \(error)")
                return
            }
            XCTAssertTrue(error.description.contains("cloud-storage placeholder"))
        }
    }

    /// A genuinely corrupt (non-zero garbage) file must NOT be
    /// misdiagnosed as a cloud placeholder -- only an all-zero byte
    /// prefix earns that specific diagnosis.
    func testNonZeroGarbageContentIsDiagnosedAsGenericUnreadable() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("garbage-\(UUID().uuidString).mp3")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data((0..<4096).map { UInt8(($0 * 37 + 11) % 256) }).write(to: file)

        do {
            _ = try await AudioDuration.seconds(ofFileAt: file)
            XCTFail("expected an error for a garbage-content file")
        } catch let error as AudioDurationError {
            guard case .unreadable = error else {
                XCTFail("expected .unreadable, got \(error)")
                return
            }
        }
    }
}
