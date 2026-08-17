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
        let args = [
            "-hide_banner", "-i", file.path,
            "-af", "loudnorm=I=\(lufsArg(targetLufs)):TP=-1.5:LRA=11:print_format=summary",
            "-f", "null", "null",
        ]
        guard let result = try? Shell.runCapturingStderr(ffmpegPath, args) else { return nil }
        return parseLoudness(from: result.stderr)
    }

    /// True if loudness couldn't be measured (nothing to flag) or sits
    /// within +/-tolerancePercent of target -- mirrors Track.
    /// loudness_is_close_to_target, which hardcoded 5%; here it's a
    /// parameter (Settings.loudnessTolerancePercent) so it's tunable
    /// from the Verify tab rather than fixed in code.
    public static func loudnessIsCloseToTarget(_ measurement: LoudnessMeasurement?, targetLufs: Double, tolerancePercent: Double = 10.0) -> Bool {
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
        return parseSilence(from: result.stderr)
    }

    /// Runs `silencedetect` and `loudnorm` chained in a single `-af`
    /// graph, so both checks share one decode of the file instead of
    /// two -- both filters pass audio through unchanged and just log
    /// their findings to stderr, so chaining them costs nothing beyond
    /// the extra filter step. `silencedetect` is placed first so it
    /// measures the original signal ahead of `loudnorm`'s gain staging.
    public static func analyzeLoudnessAndSilence(
        file: URL, targetLufs: Double, thresholdDB: Double = 90, minDurationSeconds: Double = 0.2, ffmpegPath: String
    ) -> (loudness: LoudnessMeasurement?, silenceStarts: [Double]) {
        let (loudness, silence, _) = analyzeTrack(
            file: file, targetLufs: targetLufs, thresholdDB: thresholdDB, minDurationSeconds: minDurationSeconds, ffmpegPath: ffmpegPath
        )
        return (loudness, silence)
    }

    /// Same single decode as analyzeLoudnessAndSilence, but also folds
    /// in the Frames check's decode-error scan -- used when silence,
    /// loudness, and frames are all selected together (the common case:
    /// DriveCheckOptions.slow/.all) so a track is decoded once instead
    /// of twice.
    ///
    /// `-loglevel level+info` rather than plain `-i` (analyzeLoudness/
    /// detectSilence's default level, "info") -- same verbosity,
    /// silencedetect/loudnorm's own output is unaffected, but every line
    /// now carries a `[level]` tag, so a genuine `[error]`/`[fatal]`
    /// line can be told apart from the filters' routine output. Checked
    /// against a deliberately corrupted file: ffmpeg skipped the bad
    /// packet and still exited 0, so the exit code alone isn't a
    /// reliable signal here -- the tagged line is what actually catches it.
    public static func analyzeTrack(
        file: URL, targetLufs: Double, thresholdDB: Double = 90, minDurationSeconds: Double = 0.2, ffmpegPath: String
    ) -> (loudness: LoudnessMeasurement?, silenceStarts: [Double], decodeErrorCount: Int) {
        let args = [
            "-hide_banner", "-loglevel", "level+info", "-i", file.path,
            "-af", "silencedetect=noise=-\(thresholdDB)dB:d=\(minDurationSeconds),"
                + "loudnorm=I=\(lufsArg(targetLufs)):TP=-1.5:LRA=11:print_format=summary",
            "-f", "null", "null",
        ]
        let stderr: String
        let hardFailure: Bool
        do {
            stderr = try Shell.runCapturingStderr(ffmpegPath, args).stderr
            hardFailure = false
        } catch let error as ShellError {
            guard case .failed(_, _, let capturedStderr) = error else { return (nil, [], -1) }
            stderr = capturedStderr
            hardFailure = true
        } catch {
            return (nil, [], -1)
        }
        let taggedErrors = countTaggedErrors(in: stderr)
        // A non-zero exit is a real failure even if no `[error]`-tagged
        // line happened to be captured -- same reasoning as
        // countDecodeErrors' hard-failure branch below.
        let decodeErrorCount = hardFailure ? max(taggedErrors, 1) : taggedErrors
        return (parseLoudness(from: stderr), parseSilence(from: stderr), decodeErrorCount)
    }

    /// Four independent signals the Frames check reports on -- a file
    /// can decode cleanly and still not be genuine MP3 audio, so
    /// "no decode errors" alone (the original check_frame_errors()
    /// behavior) isn't enough to call a track sound.
    public struct FrameCheckResult: Equatable {
        /// ffprobe's own codec_name for the first audio stream == "mp3".
        public let identifiesAsMP3: Bool
        /// ffprobe found a sample rate and channel count > 0 -- a file
        /// ffprobe can't make sense of reports neither.
        public let hasAudioParameters: Bool
        /// Lines of `-loglevel error` output from a full decode. -1
        /// means ffmpeg couldn't decode the file at all (non-zero exit),
        /// which is worse than any positive count and must still fail
        /// the check -- the original countFrameErrors() sentinel was
        /// silently treated as a pass by `count > 0`.
        public let decodeErrorCount: Int
        /// First bytes are an ID3 tag or a valid MPEG frame sync
        /// (0xFF followed by 3 more sync bits) -- what a player's own
        /// prober looks for before it'll even attempt to open the file.
        public let startsWithValidHeader: Bool

        public var isValid: Bool {
            identifiesAsMP3 && hasAudioParameters && decodeErrorCount == 0 && startsWithValidHeader
        }
    }

    /// Runs the four Frames sub-checks: ffprobe's codec/parameter
    /// detection, a `-loglevel error` decode (mirrors the Python
    /// original's check_frame_errors()), and a raw byte-level header
    /// check. Independent of each other -- a file can fail one without
    /// failing the rest, which is exactly the case that motivated this
    /// (a file with clean audio but no header a real player would sync
    /// to, or vice versa).
    public static func checkFrames(file: URL, ffmpegPath: String, ffprobePath: String) -> FrameCheckResult {
        checkFrames(decodeErrorCount: countDecodeErrors(file: file, ffmpegPath: ffmpegPath), file: file, ffprobePath: ffprobePath)
    }

    /// Same as checkFrames, but takes a decode-error count that was
    /// already produced by analyzeTrack's merged pass instead of running
    /// its own separate decode -- used by the combined silence+loudness+
    /// frames scan so the file isn't decoded twice.
    public static func checkFrames(decodeErrorCount: Int, file: URL, ffprobePath: String) -> FrameCheckResult {
        let probeInfo = probeStream(file: file, ffprobePath: ffprobePath)
        return FrameCheckResult(
            identifiesAsMP3: probeInfo.codecName == "mp3",
            hasAudioParameters: (probeInfo.sampleRate ?? 0) > 0 && (probeInfo.channels ?? 0) > 0,
            decodeErrorCount: decodeErrorCount,
            startsWithValidHeader: startsWithValidAudioHeader(file: file)
        )
    }

    private struct ProbeInfo {
        let codecName: String?
        let sampleRate: Int?
        let channels: Int?
    }

    private static func probeStream(file: URL, ffprobePath: String) -> ProbeInfo {
        let args = [
            "-v", "error", "-select_streams", "a:0",
            "-show_entries", "stream=codec_name,sample_rate,channels",
            "-of", "default=noprint_wrappers=1",
            file.path,
        ]
        guard let output = try? Shell.run(ffprobePath, args) else {
            return ProbeInfo(codecName: nil, sampleRate: nil, channels: nil)
        }
        let codecName = firstString(pattern: #"codec_name=(\S+)"#, in: output)
        let sampleRate = firstDouble(pattern: #"sample_rate=(\d+)"#, in: output).map(Int.init)
        let channels = firstDouble(pattern: #"channels=(\d+)"#, in: output).map(Int.init)
        return ProbeInfo(codecName: codecName, sampleRate: sampleRate, channels: channels)
    }

    /// Mirrors check_frame_errors(): a clean decode produces no
    /// error-level output at all, so any line here is a genuine
    /// frame/stream error. -1 if ffmpeg couldn't decode the file at all
    /// (distinct from, and worse than, "0 errors").
    private static func countDecodeErrors(file: URL, ffmpegPath: String) -> Int {
        let args = ["-hide_banner", "-loglevel", "error", "-i", file.path, "-f", "null", "null"]
        do {
            let result = try Shell.runCapturingStderr(ffmpegPath, args)
            return result.stderr.split(separator: "\n", omittingEmptySubsequences: true).count
        } catch let error as ShellError {
            // ffmpeg ran and exited non-zero (e.g. "Invalid data found
            // when processing input") -- that's a real failure even if
            // its stderr happened to be empty, so count it as at least 1
            // rather than folding it into the "0 errors" success case.
            if case .failed(_, _, let stderr) = error {
                return max(stderr.split(separator: "\n", omittingEmptySubsequences: true).count, 1)
            }
            return -1
        } catch {
            return -1
        }
    }

    /// Counts `[error]`/`[fatal]`/`[panic]`-tagged lines from a
    /// `-loglevel level+info` run -- the level tag can appear anywhere
    /// on the line (ffmpeg often prefixes it with a component tag, e.g.
    /// `[dec:mp3float @ 0x...] [error] ...`), so this is a substring
    /// search across the whole capture, not a per-line anchor.
    private static func countTaggedErrors(in stderr: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: #"\[(?:error|fatal|panic)\]"#) else { return 0 }
        let range = NSRange(stderr.startIndex..., in: stderr)
        return regex.numberOfMatches(in: stderr, range: range)
    }

    /// ID3v2 magic ("ID3") or an MPEG frame sync word (11 set bits: 0xFF
    /// followed by a byte with its top 3 bits set) at the start of the
    /// file -- what a real player's prober looks for before it'll even
    /// try to open the file, independent of whether ffmpeg can decode it.
    private static func startsWithValidAudioHeader(file: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 3), data.count >= 2 else { return false }
        if data.count >= 3, data[0] == 0x49, data[1] == 0x44, data[2] == 0x33 { return true } // "ID3"
        return data[0] == 0xFF && (data[1] & 0xE0) == 0xE0
    }

    private static func lufsArg(_ targetLufs: Double) -> String {
        targetLufs == targetLufs.rounded() ? String(Int(targetLufs)) : String(targetLufs)
    }

    private static func parseLoudness(from stderr: String) -> LoudnessMeasurement {
        LoudnessMeasurement(
            inputIntegrated: firstDouble(pattern: #"Input Integrated:\s*(-?\d+\.?\d*)"#, in: stderr),
            inputTruePeak: firstDouble(pattern: #"Input True Peak:\s*([+-]?\d+\.?\d*)"#, in: stderr),
            inputLRA: firstDouble(pattern: #"Input LRA:\s*(\d+\.?\d*)"#, in: stderr),
            inputThreshold: firstDouble(pattern: #"Input Threshold:\s*(-?\d+\.?\d*)"#, in: stderr),
            targetOffset: firstDouble(pattern: #"Target Offset:\s*([+-]?\d+\.?\d*)"#, in: stderr)
        )
    }

    private static func parseSilence(from stderr: String) -> [Double] {
        allDoubles(pattern: #"silence_start:\s*([\d.]+)"#, in: stderr)
    }

    private static func firstString(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1,
              let r = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[r])
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
