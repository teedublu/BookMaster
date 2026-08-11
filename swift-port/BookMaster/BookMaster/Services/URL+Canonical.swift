import Foundation
#if canImport(Darwin)
import Darwin
#endif

extension URL {
    /// Resolves macOS's APFS firmlinks (e.g. /var -> /private/var), which
    /// `URL.resolvingSymlinksInPath()` does NOT handle -- firmlinks aren't
    /// reported as traditional symlinks, so that API silently leaves them
    /// alone. Confirmed by direct testing: `FileManager.temporaryDirectory`
    /// returns an unresolved `/var/folders/...` path, while
    /// `FileManager.enumerator(at:)`'s returned child URLs resolve through
    /// `/private/var/folders/...` -- an 8-character prefix mismatch that
    /// silently corrupts any `url.path.dropFirst(root.path.count + 1)`
    /// relative-path computation (the result becomes a truncated fragment
    /// of the root's own last path component, not the real relative path).
    /// `realpath(3)` is a kernel-level syscall and resolves firmlinks
    /// correctly, unlike the URL-level API.
    func canonicalized() -> URL {
        var buf = [Int8](repeating: 0, count: Int(PATH_MAX))
        guard realpath(self.path, &buf) != nil else { return self }
        return URL(fileURLWithPath: String(cString: buf))
    }
}
