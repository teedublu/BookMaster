import AVFoundation

public enum AudioDurationError: Error, CustomStringConvertible {
    case unreadable(String)
    public var description: String {
        switch self {
        case .unreadable(let path): return "could not read duration of \(path)"
        }
    }
}

/// Reads an audio file's duration natively via AVFoundation instead of
/// shelling out to `ffprobe` — track.py's analyze_track() got this from
/// ffmpeg/ffprobe metadata; AVFoundation already ships on every Mac and
/// needs no subprocess for something this simple.
public enum AudioDuration {
    public static func seconds(ofFileAt url: URL) async throws -> Double {
        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration)
            let seconds = CMTimeGetSeconds(duration)
            guard seconds.isFinite, seconds > 0 else {
                throw AudioDurationError.unreadable(url.path)
            }
            return seconds
        } catch is AudioDurationError {
            throw AudioDurationError.unreadable(url.path)
        } catch {
            throw AudioDurationError.unreadable(url.path)
        }
    }
}
