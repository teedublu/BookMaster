import Foundation
import CryptoKit

/// Ports utils/file_helpers.py's compute_sha256(): a single running
/// SHA-256 over every file under a root directory, updated with each
/// file's POSIX-relative path (as bytes) followed by its contents, in
/// natural-sorted order — not per-file hashes concatenated, one hasher
/// fed a deterministic sequence of (path, content, path, content, ...).
/// A few housekeeping files are excluded so re-running this after
/// writing checksum.txt/version.txt doesn't change the result.
public enum Checksum {
    static let excludedNames: Set<String> = [
        ".fseventsd", ".Spotlight-V100", ".Trashes", ".DS_Store", "version.txt", "checksum.txt",
    ]

    public static func compute(rootDirectory: URL) throws -> String? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: rootDirectory, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return nil
        }

        var files: [URL] = []
        for case let url as URL in enumerator {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir { continue }
            if excludedNames.contains(url.lastPathComponent) { continue }
            files.append(url)
        }

        guard !files.isEmpty else { return nil }

        var hasher = SHA256()
        for file in files.naturalSorted(by: { $0.path }) {
            let relPath = String(file.path.dropFirst(rootDirectory.path.count + 1))
            hasher.update(data: Data(relPath.utf8))
            guard let handle = try? FileHandle(forReadingFrom: file) else { continue }
            defer { try? handle.close() }
            while true {
                let chunk = try handle.read(upToCount: 8192) ?? Data()
                if chunk.isEmpty { break }
                hasher.update(data: chunk)
            }
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
