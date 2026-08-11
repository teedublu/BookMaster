import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum DiskImageError: Error, CustomStringConvertible {
    case sourceMissing(String)
    case parseFailed(String)

    public var description: String {
        switch self {
        case .sourceMissing(let path): return "source folder does not exist: \(path)"
        case .parseFailed(let detail): return "could not parse hdiutil output: \(detail)"
        }
    }
}

public struct DiskImageResult {
    public let imagePath: URL
    public let sizeBytes: Int64
    public let volumeLabel: String
}

/// Ports diskimage.py's create_disk_image(): sizes a raw FAT image from
/// a source folder's actual disk usage plus a margin, formats it, and
/// copies the folder's contents in.
///
/// Two things changed from the Python version, both validated in
/// Phase 0:
///
/// - `mkfs.vfat` + `mtools` (Homebrew-only, not part of the macOS SDK)
///   are replaced with `/sbin/newfs_msdos` (ships on every Mac) for
///   formatting, and plain `FileManager` for copying files once the
///   image is mounted normally.
/// - Rather than `hdiutil create` (which wraps the result in a UDIF
///   container, needing a later "flatten to raw" step that Phase 0
///   flagged as unresolved), this builds a bare truncated file directly
///   with Foundation and forces hdiutil to treat it as a raw device via
///   `-imagekey diskimage-class=CRawDiskImage`. Verified on this
///   machine: the file's byte size never changes throughout the
///   attach/format/mount/copy/detach cycle — no wrapper or trailer is
///   ever added, so the result is already the flat, byte-exact image
///   Phase 4 needs to write directly to a device. This resolves the
///   Phase 0 follow-up rather than deferring it further.
///
/// Deliberately NOT ported: the Google Drive watermarking/slot-claiming
/// step (`claim_unique_slot_and_log` in the Python version) — that's a
/// business-process integration, not disk-image authoring, and out of
/// scope here.
public enum DiskImageBuilder {
    public static func buildImage(
        fromSourceFolder sourceFolder: URL,
        volumeLabel: String,
        outputPath: URL,
        patternsToExclude: [String] = ConfigStore.shared.patternsToRemove,
        log: (String) -> Void = { _ in }
    ) throws -> DiskImageResult {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: sourceFolder.path, isDirectory: &isDir), isDir.boolValue else {
            throw DiskImageError.sourceMissing(sourceFolder.path)
        }

        try fm.createDirectory(at: outputPath, withIntermediateDirectories: true)

        let workDir = fm.temporaryDirectory.appendingPathComponent("bm_img_\(UUID().uuidString)")
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workDir) }

        // Mirrors diskimage.py's format_disk_image(): strip hyphens,
        // uppercase, 11-char FAT volume-label limit.
        let sanitizedLabel = String(volumeLabel.replacingOccurrences(of: "-", with: "").uppercased().prefix(11))
        let stagingPath = workDir.appendingPathComponent("\(volumeLabel).img")

        // 1) size the image from the source folder's actual disk usage,
        //    matching diskimage.py's exact 5%-or-5MB-buffer, 10MB-floor logic.
        let sourceSizeKB = try directorySizeKB(at: sourceFolder)
        let bufferKB = max(sourceSizeKB / 20, 5 * 1024)
        let imageSizeMB = max((sourceSizeKB + bufferKB + 1023) / 1024, 10)
        let imageSizeBytes = Int64(imageSizeMB) * 1024 * 1024
        log("Sizing image: source=\(sourceSizeKB)KB buffer=\(bufferKB)KB -> \(imageSizeMB)MB")

        // 2) bare truncated raw file -- see doc comment above.
        guard fm.createFile(atPath: stagingPath.path, contents: nil) else {
            throw DiskImageError.parseFailed("could not create staging file at \(stagingPath.path)")
        }
        let handle = try FileHandle(forWritingTo: stagingPath)
        try handle.truncate(atOffset: UInt64(imageSizeBytes))
        try handle.close()

        // 3) format directly on the raw device node.
        let fatBits = imageSizeMB < 40 ? "16" : "32"
        let nomountOut = try Shell.run("/usr/bin/hdiutil", [
            "attach", "-imagekey", "diskimage-class=CRawDiskImage", "-nomount", stagingPath.path,
        ])
        guard let device = Shell.devicePath(fromAttachOutput: nomountOut) else {
            throw DiskImageError.parseFailed(nomountOut)
        }
        let rawDevice = device.replacingOccurrences(of: "/dev/disk", with: "/dev/rdisk")
        log("Formatting \(rawDevice) as FAT\(fatBits), label \(sanitizedLabel)")
        try Shell.run("/sbin/newfs_msdos", ["-F", fatBits, "-v", sanitizedLabel, rawDevice])
        try Shell.run("/usr/bin/hdiutil", ["detach", device])

        // 4) mount and copy the folder's contents in, respecting the
        //    exclude patterns (._*, .DS_Store, etc. from config.json).
        let mountOut = try Shell.run("/usr/bin/hdiutil", [
            "attach", "-imagekey", "diskimage-class=CRawDiskImage", "-nobrowse", stagingPath.path,
        ])
        guard let mountedDevice = Shell.devicePath(fromAttachOutput: mountOut),
              let mountPoint = Shell.mountPath(fromAttachOutput: mountOut) else {
            throw DiskImageError.parseFailed(mountOut)
        }
        do {
            try copyContents(of: sourceFolder, to: URL(fileURLWithPath: mountPoint), excluding: patternsToExclude, log: log)
        } catch {
            try? Shell.run("/usr/bin/hdiutil", ["detach", mountedDevice])
            throw error
        }
        try Shell.run("/usr/bin/hdiutil", ["detach", mountedDevice])

        // 5) publish to the real output location.
        let finalPath = outputPath.appendingPathComponent("\(volumeLabel).img")
        if fm.fileExists(atPath: finalPath.path) {
            try fm.removeItem(at: finalPath)
        }
        do {
            try fm.moveItem(at: stagingPath, to: finalPath)
        } catch {
            // Cross-volume fallback, mirroring diskimage.py's os.replace -> copy2 fallback.
            try fm.copyItem(at: stagingPath, to: finalPath)
            try? fm.removeItem(at: stagingPath)
        }
        lockReadOnly(finalPath)

        let finalSize = (try? fm.attributesOfItem(atPath: finalPath.path)[.size] as? Int64) ?? nil
        let sizeBytes = finalSize ?? imageSizeBytes
        log("Disk image created: \(finalPath.path) (\(sizeBytes) bytes)")
        return DiskImageResult(imagePath: finalPath, sizeBytes: sizeBytes, volumeLabel: sanitizedLabel)
    }

    // MARK: - Helpers

    private static func directorySizeKB(at url: URL) throws -> Int {
        let output = try Shell.run("/usr/bin/du", ["-sk", url.path])
        let firstField = output.split(whereSeparator: { $0 == "\t" || $0 == " " }).first
        guard let firstField, let kb = Int(firstField) else {
            throw DiskImageError.parseFailed("`du -sk` output: \(output)")
        }
        return kb
    }

    private static func isExcluded(_ url: URL, relativeTo root: URL, patterns: [String]) -> Bool {
        let relPath = String(url.path.dropFirst(root.path.count + 1))
        let name = url.lastPathComponent
        return patterns.contains { pattern in
            fnmatch(pattern, relPath, 0) == 0 || fnmatch(pattern, name, 0) == 0
        }
    }

    private static func copyContents(of sourceFolder: URL, to destination: URL, excluding patterns: [String], log: (String) -> Void) throws {
        let fm = FileManager.default

        func copyRecursive(_ dir: URL, destDir: URL) throws {
            let entries = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [])
            for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                if isExcluded(entry, relativeTo: sourceFolder, patterns: patterns) { continue }
                let isDirEntry = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                let destEntry = destDir.appendingPathComponent(entry.lastPathComponent)
                if isDirEntry {
                    try fm.createDirectory(at: destEntry, withIntermediateDirectories: true)
                    try copyRecursive(entry, destDir: destEntry)
                } else {
                    log("Copying \(entry.lastPathComponent)")
                    try fm.copyItem(at: entry, to: destEntry)
                }
            }
        }

        try copyRecursive(sourceFolder, destDir: destination)
    }

    /// Mirrors diskimage.py's DiskImage._lock_readonly.
    private static func lockReadOnly(_ path: URL) {
        try? Shell.run("/bin/chmod", ["444", path.path])
        try? Shell.run("/usr/bin/chflags", ["uchg", path.path])
    }
}
