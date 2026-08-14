import Foundation

public enum FFmpegError: Error, CustomStringConvertible {
    case ffmpegNotFound
    case encodingFailed(String)

    public var description: String {
        switch self {
        case .ffmpegNotFound:
            return "ffmpeg not found (checked common Homebrew paths and $PATH)"
        case .encodingFailed(let detail):
            return "ffmpeg encoding failed: \(detail)"
        }
    }
}

public struct EncodeParameters {
    public let sampleRate: Int
    public let bitRate: Int // bits per second, e.g. 96000
    public let targetLufs: Double
    public let durationSeconds: Double
    /// When true, the output track carries no metadata at all -- not
    /// the input file's own tags (ffmpeg copies global metadata from
    /// input to output by default, absent `-map_metadata -1`) and not
    /// even ffmpeg's own encoder tag (absent `-id3v2_version 0`, the
    /// mp3 muxer writes a minimal ID3v2 tag itself). See "Strip Audio
    /// Tags" in Create Master's Options.
    public let stripMetadata: Bool

    public init(sampleRate: Int, bitRate: Int, targetLufs: Double, durationSeconds: Double, stripMetadata: Bool = false) {
        self.sampleRate = sampleRate
        self.bitRate = bitRate
        self.targetLufs = targetLufs
        self.durationSeconds = durationSeconds
        self.stripMetadata = stripMetadata
    }
}

/// Ports track.py's Track.convert(): the exact same ffmpeg filter graph
/// (pink-noise dither mixed in at a=0.0001 before loudness
/// normalization — not something to "clean up" or reinterpret, just
/// reproduce byte-for-byte as a command line, since it's known-working
/// production audio processing), invoked via Process instead of the
/// ffmpeg-python wrapper.
///
/// AVFoundation was considered and deliberately NOT used for the actual
/// encoding — it has no equivalent to ffmpeg's `loudnorm` filter, and
/// getting loudness normalization subtly wrong would make every
/// audiobook sound different. This keeps ffmpeg as an external
/// dependency (Phase 9 needs to bundle+sign it) rather than reimplement
/// audio DSP.
public enum FFmpegEncoder {
    public static func locateFFmpeg() -> String? {
        let candidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        // Fall back to $PATH resolution via /usr/bin/env, matching how a
        // shell would find it if none of the common install locations hit.
        if let output = try? Shell.run("/usr/bin/env", ["which", "ffmpeg"]) {
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    /// Mirrors Track.convert()'s exact filter_complex string:
    /// `[a0]volume=1.0[a1]; anoisesrc=r=44100:c=pink:a=0.0001:d={duration}[a2];
    ///  [a1][a2]amix=inputs=2:duration=first:dropout_transition=3[a3];
    ///  [a3]loudnorm=I={target_lufs}:LRA=11:TP=-1.5[out]`
    static func filterComplex(targetLufs: Double, durationSeconds: Double) -> String {
        let lufs = targetLufs == targetLufs.rounded() ? String(Int(targetLufs)) : String(targetLufs)
        return "[a0]volume=1.0[a1]; " +
               "anoisesrc=r=44100:c=pink:a=0.0001:d=\(durationSeconds)[a2]; " +
               "[a1][a2]amix=inputs=2:duration=first:dropout_transition=3[a3]; " +
               "[a3]loudnorm=I=\(lufs):LRA=11:TP=-1.5[out]"
    }

    @discardableResult
    public static func encode(
        inputPath: URL,
        outputPath: URL,
        parameters: EncodeParameters,
        ffmpegPath: String? = nil
    ) throws -> URL {
        guard let ffmpeg = ffmpegPath ?? locateFFmpeg() else {
            throw FFmpegError.ffmpegNotFound
        }

        try FileManager.default.createDirectory(at: outputPath.deletingLastPathComponent(), withIntermediateDirectories: true)

        let filter = filterComplex(targetLufs: parameters.targetLufs, durationSeconds: parameters.durationSeconds)
        var args = [
            "-y",
            "-i", inputPath.path,
            "-filter_complex", filter,
            "-map", "[out]",
            "-ar", "\(parameters.sampleRate)",
            "-ab", "\(parameters.bitRate / 1000)k",
            "-ac", "1",
            "-f", "mp3",
            "-acodec", "libmp3lame",
        ]
        if parameters.stripMetadata {
            // -map_metadata -1: don't carry the input file's own tags
            // through (ffmpeg's default is to copy them).
            // -id3v2_version 0: don't write an ID3v2 tag at all, so the
            // mp3 muxer's own minimal tag doesn't sneak back in either.
            args += ["-map_metadata", "-1", "-id3v2_version", "0"]
        }
        args.append(outputPath.path)

        do {
            try Shell.run(ffmpeg, args)
        } catch let error as ShellError {
            throw FFmpegError.encodingFailed(error.description)
        }
        return outputPath
    }
}
