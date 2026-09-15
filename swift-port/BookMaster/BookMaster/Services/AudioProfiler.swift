import Foundation
import AudioToolbox

public struct AudioProfileResult: Equatable {
    public let durationSeconds: Int?
    public let averageKbps: Double?
    public let parsedFileCount: Int
}

/// Ports util.py's measure_track_audio_bytes()/inspect_tracks_audio_profile():
/// estimates a track folder's total playback duration and average
/// encoding bitrate, either by sampling one file (quick) or inspecting
/// every file (full scan).
///
/// Rates come from each file's audio data, not its size on disk, so ID3 tags and encoder headers can't inflate a short track's figure.
public enum AudioProfiler {
    public static let trackAudioExtensions: Set<String> = [
        ".aac", ".aif", ".aifc", ".aiff", ".m4a", ".m4b", ".mp3", ".mps", ".wav",
    ]

    /// Ports `_track_audio_candidates`: files matching known audio
    /// extensions, or every file if none match (mirrors the Python
    /// fallback so a folder of oddly-named tracks doesn't just come up
    /// empty).
    static func candidateFiles(in tracksPath: URL) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: tracksPath, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return []
        }
        var all: [URL] = []
        for case let url as URL in enumerator {
            let isFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
            if isFile { all.append(url) }
        }
        all.sort { $0.path.lowercased() < $1.path.lowercased() }
        let audioFiles = all.filter { trackAudioExtensions.contains(".\($0.pathExtension.lowercased())") }
        return audioFiles.isEmpty ? all : audioFiles
    }

    public static func measureTrackAudioBytes(tracksPath: URL) -> (totalBytes: Int64, fileCount: Int) {
        let fm = FileManager.default
        var totalBytes: Int64 = 0
        var counted = 0
        for file in candidateFiles(in: tracksPath) {
            guard let size = try? fm.attributesOfItem(atPath: file.path)[.size] as? Int64 else { continue }
            totalBytes += size
            counted += 1
        }
        return (totalBytes, counted)
    }

    /// One file's duration and audio data size as AudioToolbox parses them (what afinfo prints), or nil if it can't read the file.
    private static func probe(_ file: URL) -> (duration: Double, audioBytes: Int64)? {
        var fileID: AudioFileID?
        guard AudioFileOpenURL(file as CFURL, .readPermission, 0, &fileID) == noErr, let fileID else { return nil }
        defer { AudioFileClose(fileID) }

        var duration: Float64 = 0
        var durationSize = UInt32(MemoryLayout<Float64>.size)
        var audioBytes: UInt64 = 0
        var audioBytesSize = UInt32(MemoryLayout<UInt64>.size)
        guard AudioFileGetProperty(fileID, kAudioFilePropertyEstimatedDuration, &durationSize, &duration) == noErr,
              AudioFileGetProperty(fileID, kAudioFilePropertyAudioDataByteCount, &audioBytesSize, &audioBytes) == noErr,
              duration.isFinite, duration > 0, audioBytes > 0 else { return nil }
        return (duration, Int64(audioBytes))
    }

    public static func inspectTracksAudioProfile(tracksPath: URL, fullScan: Bool) async -> AudioProfileResult {
        let files = candidateFiles(in: tracksPath)
        guard !files.isEmpty else { return AudioProfileResult(durationSeconds: nil, averageKbps: nil, parsedFileCount: 0) }

        if !fullScan {
            let (totalBytes, _) = measureTrackAudioBytes(tracksPath: tracksPath)
            guard let first = files.first, let probed = probe(first) else {
                return AudioProfileResult(durationSeconds: nil, averageKbps: nil, parsedFileCount: 0)
            }
            let measuredBps = Double(probed.audioBytes) * 8.0 / probed.duration
            let totalSecs = totalBytes > 0 ? Int((Double(totalBytes) * 8.0 / measuredBps).rounded()) : Int(probed.duration.rounded())
            return AudioProfileResult(durationSeconds: max(1, totalSecs), averageKbps: (measuredBps / 1000.0 * 10).rounded() / 10, parsedFileCount: 1)
        }

        var totalDuration = 0.0
        var parsedAudioBytes: Int64 = 0
        var unparsedBytes: Int64 = 0
        var parsed = 0

        for file in files {
            guard let probed = probe(file) else {
                unparsedBytes += (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? 0
                continue
            }
            totalDuration += probed.duration
            parsedAudioBytes += probed.audioBytes
            parsed += 1
        }

        guard parsed > 0 else {
            return AudioProfileResult(durationSeconds: nil, averageKbps: nil, parsedFileCount: 0)
        }

        let measuredBps = Double(parsedAudioBytes) * 8.0 / totalDuration
        let finalDuration = totalDuration + Double(unparsedBytes) * 8.0 / measuredBps
        let avgKbps = (measuredBps / 1000.0 * 10).rounded() / 10

        return AudioProfileResult(durationSeconds: Int(finalDuration.rounded()), averageKbps: avgKbps, parsedFileCount: parsed)
    }
}
