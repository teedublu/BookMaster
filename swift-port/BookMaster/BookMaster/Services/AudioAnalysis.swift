import Foundation

public struct TrackAudioIssue: Equatable {
    public let fileName: String
    public let reason: String
}

/// Per-track ffmpeg analysis backing the Verify tab's Silence/Loudness/
/// Frames checks -- ports audio_helper.py's analyze_loudness()/
/// detect_silence()/check_frame_errors() and track.py's
/// loudness_is_close_to_target. All three decode each track's full
/// audio, unlike the cheap Metadata (ID3-only) and Speed (fixed-size
/// raw read) checks -- see DriveCheckOptions.slow in DriveVerifier.swift.
public enum AudioAnalysis {
    public struct LoudnessMeasurement: Equatable {
        public let inputIntegrated: Double?
        public let inputTruePeak: Double?
        public let inputLRA: Double?
        public let inputThreshold: Double?
        public let targetOffset: Double?
    }

    /// ffmpeg's loudnorm filter in single-pass "summary" mode -- same
    /// invocation as analyze_loudness(). Reads the human-readable
    /// summary block loudnorm writes to stderr with the same labeled
    /// regexes the Python version uses.
    public static func analyzeLoudness(file: URL, targetLufs: Double, ffmpegPath: String) -> LoudnessMeasurement? {
        let lufs = targetLufs == targetLufs.rounded() ? String(Int(targetLufs)) : String(targetLufs)
        let args = [
            "-hide_banner", "-i", file.path,
            "-af", "loudnorm=I=\(lufs):TP=-1.5:LRA=11:print_format=summary",
            "-f", "null", "null",
        ]
        guard let result = try? Shell.runCapturingStderr(ffmpegPath, args) else { return nil }
        let stderr = result.stderr
        return LoudnessMeasurement(
            inputIntegrated: firstDouble(pattern: #"Input Integrated:\s*(-?\d+\.?\d*)"#, in: stderr),
            inputTruePeak: firstDouble(pattern: #"Input True Peak:\s*([+-]?\d+\.?\d*)"#, in: stderr),
            inputLRA: firstDouble(pattern: #"Input LRA:\s*(\d+\.?\d*)"#, in: stderr),
            inputThreshold: firstDouble(pattern: #"Input Threshold:\s*(-?\d+\.?\d*)"#, in: stderr),
            targetOffset: firstDouble(pattern: #"Target Offset:\s*([+-]?\d+\.?\d*)"#, in: stderr)
        )
    }

    /// True if loudness couldn't be measured (nothing to flag) or sits
    /// within +/-tolerancePercent of target -- mirrors Track.
    /// loudness_is_close_to_target, which hardcoded 5%; here it's a
    /// parameter (Settings.loudnessTolerancePercent) so it's tunable
    /// from the Verify tab rather than fixed in code.
    public static func loudnessIsCloseToTarget(_ measurement: LoudnessMeasurement?, targetLufs: Double, tolerancePercent: Double = 5.0) -> Bool {
        guard let measured = measurement?.inputIntegrated else { return true }
        let deviation = abs(measured - targetLufs)
        let allowedDeviation = abs(targetLufs) * (tolerancePercent / 100.0)
        return deviation <= allowedDeviation
    }

    /// ffmpeg's silencedetect filter -- returns each silence_start
    /// timestamp (seconds) found. Mirrors detect_silence()'s defaults:
    /// -90dB noise floor, 0.2s minimum run length.
    public static func detectSilence(
        file: URL, thresholdDB: Double = 90, minDurationSeconds: Double = 0.2, ffmpegPath: String
    ) -> [Double] {
        let args = [
            "-hide_banner", "-i", file.path,
            "-af", "silencedetect=noise=-\(thresholdDB)dB:d=\(minDurationSeconds)",
            "-f", "null", "null",
        ]
        guard let result = try? Shell.runCapturingStderr(ffmpegPath, args) else { return [] }
        return allDoubles(pattern: #"silence_start:\s*([\d.]+)"#, in: result.stderr)
    }

    /// Decodes with `-loglevel error` and counts stderr lines -- mirrors
    /// check_frame_errors(): a clean decode produces no error-level
    /// output at all, so any line here is a genuine frame/stream error.
    /// Returns -1 if ffmpeg itself couldn't be run, matching the
    /// Python version's error sentinel.
    public static func countFrameErrors(file: URL, ffmpegPath: String) -> Int {
        let args = ["-hide_banner", "-loglevel", "error", "-i", file.path, "-f", "null", "null"]
        guard let result = try? Shell.runCapturingStderr(ffmpegPath, args) else { return -1 }
        return result.stderr.split(separator: "\n", omittingEmptySubsequences: true).count
    }

    private static func firstDouble(pattern: String, in text: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1,
              let r = Range(match.range(at: 1), in: text) else { return nil }
        return Double(text[r])
    }

    private static func allDoubles(pattern: String, in text: String) -> [Double] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: range)
        return matches.compactMap { match in
            guard match.numberOfRanges > 1, let r = Range(match.range(at: 1), in: text) else { return nil }
            return Double(text[r])
        }
    }
}
