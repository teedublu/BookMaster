import Foundation
import AVFoundation

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
/// Uses native AVFoundation (AVURLAsset.load(.duration)) instead of
/// shelling out to `afinfo` -- already established in Phase 6's
/// AudioDuration.swift. This also happens to match what the Python
/// code actually prioritizes: it computes "measured_bps" from
/// (file_bytes * 8 / duration) and prefers that over afinfo's own
/// reported bit-rate field whenever it's available, so accurate
/// duration + file size (both trivial with AVFoundation) covers the
/// primary code path faithfully without needing afinfo's raw bitrate
/// parsing at all.
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

    /// One file's (duration, byte size), or nil if AVFoundation couldn't
    /// read it (mirrors afinfo failing to parse a file -- treated as
    /// unparsed, not a hard error, same as the Python version).
    private static func probe(_ file: URL) async -> (duration: Double, bytes: Int64)? {
        let asset = AVURLAsset(url: file)
        guard let duration = try? await asset.load(.duration) else { return nil }
        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite, seconds > 0 else { return nil }
        guard let bytes = try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64 else { return nil }
        return (seconds, bytes)
    }

    public static func inspectTracksAudioProfile(tracksPath: URL, fullScan: Bool) async -> AudioProfileResult {
        let files = candidateFiles(in: tracksPath)
        guard !files.isEmpty else { return AudioProfileResult(durationSeconds: nil, averageKbps: nil, parsedFileCount: 0) }

        if !fullScan {
            let (totalBytes, _) = measureTrackAudioBytes(tracksPath: tracksPath)
            guard let first = files.first, let probed = await probe(first) else {
                return AudioProfileResult(durationSeconds: nil, averageKbps: nil, parsedFileCount: 0)
            }
            let measuredBps = (Double(probed.bytes) * 8.0) / probed.duration
            guard measuredBps > 0 else {
                return AudioProfileResult(durationSeconds: nil, averageKbps: nil, parsedFileCount: 0)
            }
            let totalSecs = totalBytes > 0 ? Int((Double(totalBytes) * 8.0 / measuredBps).rounded()) : Int(probed.duration.rounded())
            return AudioProfileResult(durationSeconds: max(1, totalSecs), averageKbps: (measuredBps / 1000.0 * 10).rounded() / 10, parsedFileCount: 1)
        }

        var totalDuration = 0.0
        var parsedBytes: Int64 = 0
        var unparsedBytes: Int64 = 0
        var parsed = 0

        for file in files {
            let fileBytes = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? 0
            guard let probed = await probe(file) else {
                unparsedBytes += fileBytes
                continue
            }
            totalDuration += probed.duration
            parsed += 1
            parsedBytes += probed.bytes
        }

        guard parsed > 0, totalDuration > 0 else {
            return AudioProfileResult(durationSeconds: nil, averageKbps: nil, parsedFileCount: 0)
        }

        var finalDuration = totalDuration
        var observedBps: Double? = parsedBytes > 0 ? (Double(parsedBytes) * 8.0) / totalDuration : nil
        if unparsedBytes > 0, let bps = observedBps, bps > 0 {
            finalDuration += (Double(unparsedBytes) * 8.0) / bps
        }

        let profileBytes = parsedBytes + unparsedBytes
        var avgKbps: Double?
        if profileBytes > 0 {
            avgKbps = (Double(profileBytes) * 8.0 / finalDuration / 1000.0 * 10).rounded() / 10
        } else {
            avgKbps = observedBps.map { ($0 / 1000.0 * 10).rounded() / 10 }
        }

        return AudioProfileResult(durationSeconds: Int(finalDuration.rounded()), averageKbps: avgKbps, parsedFileCount: parsed)
    }
}
