import AVFoundation

public enum AudioDurationError: Error, CustomStringConvertible {
    case unreadable(String)
    case looksLikeUnsyncedPlaceholder(String)

    public var description: String {
        switch self {
        case .unreadable(let path):
            return "could not read duration of \(path)"
        case .looksLikeUnsyncedPlaceholder(let path):
            return "could not read duration of \(path) — its content is entirely zero bytes, which looks like an "
                + "unsynced cloud-storage placeholder (e.g. Google Drive hasn't actually downloaded it yet) rather "
                + "than real audio. In Finder, right-click the containing folder and force it to download/be kept "
                + "offline, then retry."
        }
    }
}

/// Reads an audio file's duration natively via AVFoundation instead of
/// shelling out to `ffprobe` — track.py's analyze_track() got this from
/// ffmpeg/ffprobe metadata; AVFoundation already ships on every Mac and
/// needs no subprocess for something this simple.
public enum AudioDuration {
    /// How much of a failed file to sample when deciding whether it
    /// looks like an unsynced cloud-storage placeholder rather than a
    /// genuinely corrupt file. Confirmed by hand against a real failure:
    /// a Google Drive-mounted input file reported its correct final
    /// size (6.5MB) and passed every metadata check (UTI, Spotlight),
    /// but every byte of its actual content was 0x00 -- Drive's local
    /// client had allocated the file but not yet streamed in the real
    /// bytes. AVFoundation's own error for that case is just a generic,
    /// unhelpful "could not be opened", so this distinguishes the two
    /// causes to give a diagnosis actually worth acting on.
    private static let placeholderProbeByteCount = 4096

    public static func seconds(ofFileAt url: URL) async throws -> Double {
        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration)
            let seconds = CMTimeGetSeconds(duration)
            guard seconds.isFinite, seconds > 0 else {
                throw resolvedError(for: url)
            }
            return seconds
        } catch {
            throw resolvedError(for: url)
        }
    }

    private static func resolvedError(for url: URL) -> AudioDurationError {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return .unreadable(url.path)
        }
        defer { try? handle.close() }
        let sample = (try? handle.read(upToCount: placeholderProbeByteCount)) ?? Data()
        if !sample.isEmpty, sample.allSatisfy({ $0 == 0 }) {
            return .looksLikeUnsyncedPlaceholder(url.path)
        }
        return .unreadable(url.path)
    }
}
