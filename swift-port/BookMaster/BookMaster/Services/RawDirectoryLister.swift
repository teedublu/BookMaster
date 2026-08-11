import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// A directory listing that bypasses Foundation's silent filtering of
/// "._*" AppleDouble sidecar files.
///
/// Confirmed by direct testing (both in a plain APFS temp directory and
/// on a real mounted FAT16 volume built with newfs_msdos): a file
/// literally named "._foo" exists on disk and `FileManager.fileExists`
/// finds it, but `FileManager.contentsOfDirectory` and
/// `FileManager.enumerator(at:)` never list it at all -- Foundation
/// treats anything matching that naming convention as an internal
/// AppleDouble metadata companion, invisible to normal directory
/// listing, regardless of whether it's genuinely an AppleDouble file or
/// just happens to be named that way. These are exactly the files most
/// likely to accumulate as macOS cruft on a FAT-formatted USB drive
/// (macOS stores extended attributes as "._filename" sidecars on
/// filesystems without native xattr support), so code that cleans up a
/// live mounted drive cannot rely on FileManager's directory APIs to
/// find them -- it would silently miss an entire class of real files.
///
/// Uses POSIX `opendir`/`readdir`/`closedir` directly (a kernel-level
/// syscall, not a Foundation abstraction) to enumerate every entry with
/// no filtering at all.
enum RawDirectoryLister {
    /// Every entry's name in one directory (not recursive), excluding
    /// "." and "..". Empty if the directory can't be opened.
    static func entries(at path: URL) -> [String] {
        guard let dir = opendir(path.path) else { return [] }
        defer { closedir(dir) }

        var names: [String] = []
        while let entry = readdir(dir) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw -> String in
                let ptr = raw.baseAddress!.assumingMemoryBound(to: CChar.self)
                return String(cString: ptr)
            }
            if name == "." || name == ".." { continue }
            names.append(name)
        }
        return names
    }

    /// Recursively lists every file and directory under `root`,
    /// returning paths relative to it (POSIX-separated). Directories
    /// are included in the result alongside files.
    static func allEntriesRecursively(at root: URL) -> [String] {
        var results: [String] = []

        func walk(_ dir: URL, prefix: String) {
            for name in entries(at: dir).sorted() {
                let relPath = prefix.isEmpty ? name : "\(prefix)/\(name)"
                results.append(relPath)
                let childURL = dir.appendingPathComponent(name)
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: childURL.path, isDirectory: &isDir), isDir.boolValue {
                    walk(childURL, prefix: relPath)
                }
            }
        }

        walk(root, prefix: "")
        return results
    }
}
