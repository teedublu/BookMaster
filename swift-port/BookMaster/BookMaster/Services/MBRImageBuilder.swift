import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum MBRImageError: Error, CustomStringConvertible {
    case sourceMissing(String)
    case parseFailed(String)
    case validationFailed(String)

    public var description: String {
        switch self {
        case .sourceMissing(let path): return "source folder does not exist: \(path)"
        case .parseFailed(let detail): return "could not parse hdiutil/diskutil output: \(detail)"
        case .validationFailed(let detail): return "rebuilt image failed validation: \(detail)"
        }
    }
}

/// Ports rebuilder.py's MBR-partitioned image creation -- the option
/// this app's Create Master needs alongside the existing bare-FAT
/// superfloppy layout (DiskImageBuilder), for target hardware that
/// expects a real MBR partition table.
///
/// Confirmed on this machine before writing this: `hdiutil create -size
/// N -layout NONE` alone (no CRawDiskImage forcing) already produces a
/// byte-exact file with no UDIF trailer -- verified by hexdumping the
/// last 1KB of a freshly created image and finding no koly signature.
/// `diskutil partitionDisk <dev> MBRFormat FAT32 <label> 100%` then
/// writes both the MBR partition table and the FAT32 filesystem in one
/// step; there is no hand-rolled MBR-byte-construction here, matching
/// what voxmaster's Python actually does (byte-level parsing is only
/// used for read-side inspection/validation, in ImageLayoutInspector).
/// Also confirmed for real: partitionDisk fails ("-69850: chosen size
/// is not valid") below roughly 128MiB for FAT32, which is exactly why
/// voxmaster's own minimum floor is 128MiB.
public enum MBRImageBuilder {
    static let sectorSize = 512
    static let mb: Int64 = 1_000_000
    static let mib: Int64 = 1024 * 1024
    static let fat32MinImageBytes: Int64 = 128 * 1024 * 1024
    static let freeSpaceMarginBytes: Int64 = 32 * 1024 * 1024
    static let boundaryHeadroomBytes: Int64 = 5 * 1_000_000
    static let imageBucketBytes: [Int64] = [128 * mib, 256 * mib, 475 * mb, 975 * mb]

    /// Ports `_destination_image_bytes`: smallest bucket that fits
    /// `usedBytes + 32MiB margin` (128/256 MiB, 475/975 MB), or above
    /// that, the smallest whole number of decimal GB minus 5MB headroom
    /// (so nominal media has breathing room instead of landing exactly
    /// on a boundary).
    public static func destinationImageBytes(usedBytes: Int64, minSizeMib: Int) -> Int64 {
        let minBytes = max(fat32MinImageBytes, Int64(minSizeMib) * mib)
        let requiredBytes = ceilToSector(max(minBytes, usedBytes + freeSpaceMarginBytes))

        for bucket in imageBucketBytes {
            let flooredBucket = floorToSector(bucket)
            if requiredBytes <= flooredBucket { return flooredBucket }
        }

        let decimalGB: Int64 = 1000 * mb
        let gbCount = max(2, (requiredBytes + boundaryHeadroomBytes + decimalGB - 1) / decimalGB)
        return floorToSector((gbCount * decimalGB) - boundaryHeadroomBytes)
    }

    /// Ports `_safe_volume_label`: strip control chars and path
    /// separators, cap at 11 characters (FAT volume label limit).
    public static func safeVolumeLabel(_ label: String?, fallback: String) -> String {
        let raw = (label?.isEmpty == false ? label! : fallback)
        let cleaned = raw.unicodeScalars.filter { scalar in
            scalar.value >= 32 && scalar.value <= 126 && !"/:\n\r\t".unicodeScalars.contains(scalar)
        }
        let result = String(String.UnicodeScalarView(cleaned)).prefix(11)
        return result.isEmpty ? String(fallback.prefix(11).isEmpty ? "VOXMASTER" : fallback.prefix(11)) : String(result)
    }

    private static func floorToSector(_ bytes: Int64) -> Int64 { (bytes / Int64(sectorSize)) * Int64(sectorSize) }
    private static func ceilToSector(_ bytes: Int64) -> Int64 { ((bytes + Int64(sectorSize) - 1) / Int64(sectorSize)) * Int64(sectorSize) }

    /// Builds an MBR-partitioned FAT32 image from a source folder --
    /// the MBR equivalent of DiskImageBuilder.buildImage(). Reuses that
    /// function's exclusion-pattern-based copy logic conceptually, but
    /// copies into a real mounted FAT32 volume (via `diskutil
    /// partitionDisk`) rather than a bare superfloppy filesystem.
    public static func buildImage(
        fromSourceFolder sourceFolder: URL,
        volumeLabel: String,
        outputPath: URL,
        minSizeMib: Int = 128,
        patternsToExclude: [String] = ConfigStore.shared.patternsToRemove,
        log: (String) -> Void = { _ in }
    ) throws -> DiskImageResult {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: sourceFolder.path, isDirectory: &isDir), isDir.boolValue else {
            throw MBRImageError.sourceMissing(sourceFolder.path)
        }
        try fm.createDirectory(at: outputPath, withIntermediateDirectories: true)

        let workDir = fm.temporaryDirectory.appendingPathComponent("bm_mbr_\(UUID().uuidString)")
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workDir) }

        let safeLabel = safeVolumeLabel(String(volumeLabel.replacingOccurrences(of: "-", with: "").uppercased().prefix(11)), fallback: "VOXMASTER")
        // hdiutil infers format from a .dmg-suffixed name; the final
        // published artifact still ends in .img (renamed at the end).
        let stagingDmg = workDir.appendingPathComponent("\(volumeLabel).img.dmg")

        let usedBytes = try Int64(directorySizeKB(at: sourceFolder)) * 1024
        let imageSizeBytes = destinationImageBytes(usedBytes: usedBytes, minSizeMib: minSizeMib)
        log("Sizing MBR image: used=\(usedBytes) bytes -> \(imageSizeBytes) bytes bucket")

        try Shell.run("/usr/bin/hdiutil", ["create", "-size", String(imageSizeBytes), "-layout", "NONE", "-ov", stagingDmg.path])

        let nomountOut = try Shell.run("/usr/bin/hdiutil", ["attach", "-nomount", "-nobrowse", stagingDmg.path])
        guard let device = Shell.devicePath(fromAttachOutput: nomountOut) else {
            throw MBRImageError.parseFailed(nomountOut)
        }

        do {
            log("Partitioning \(device) as MBR + FAT32, label \(safeLabel)")
            try Shell.run("/usr/sbin/diskutil", ["partitionDisk", device, "MBRFormat", "FAT32", safeLabel, "100%"])
        } catch {
            try? Shell.run("/usr/bin/hdiutil", ["detach", device])
            throw error
        }

        // partitionDisk automounts the new (empty) FAT volume; find it,
        // clean any artifacts the OS synthesized, then copy real content in.
        let partitionDevice = device + "s1"
        guard let mountPoint = try mountPointFor(device: partitionDevice) else {
            try? Shell.run("/usr/bin/hdiutil", ["detach", device])
            throw MBRImageError.parseFailed("could not find mount point for \(partitionDevice) after partitioning")
        }
        let mountURL = URL(fileURLWithPath: mountPoint)

        do {
            removeExcludedEntries(at: mountURL, patterns: patternsToExclude)
            try copyContents(of: sourceFolder, to: mountURL, excluding: patternsToExclude, log: log)
            removeExcludedEntries(at: mountURL, patterns: patternsToExclude)
        } catch {
            try? Shell.run("/usr/bin/hdiutil", ["detach", device])
            throw error
        }
        try Shell.run("/usr/bin/hdiutil", ["detach", device])

        // Validate: re-inspect the raw bytes to confirm this really is
        // MBR+FAT32 with the expected label, and mount read-only to
        // confirm no macOS metadata slipped back in.
        let layout = try ImageLayoutInspector.inspect(stagingDmg)
        guard layout.kind == .mbrFat else {
            throw MBRImageError.validationFailed("expected mbr-fat, got \(layout.kind.rawValue)")
        }
        guard layout.fatVariant == "FAT32" else {
            throw MBRImageError.validationFailed("expected FAT32, got \(layout.fatVariant ?? "nil")")
        }
        guard let startLBA = layout.partitionStartLBA, startLBA > 0 else {
            throw MBRImageError.validationFailed("partition does not start after sector 0")
        }

        let finalPath = outputPath.appendingPathComponent("\(volumeLabel).img")
        if fm.fileExists(atPath: finalPath.path) {
            try fm.removeItem(at: finalPath)
        }
        do {
            try fm.moveItem(at: stagingDmg, to: finalPath)
        } catch {
            try fm.copyItem(at: stagingDmg, to: finalPath)
            try? fm.removeItem(at: stagingDmg)
        }

        let finalSize = (try? fm.attributesOfItem(atPath: finalPath.path)[.size] as? Int64) ?? imageSizeBytes
        log("MBR image created: \(finalPath.path) (\(finalSize) bytes, partition @ LBA \(startLBA))")
        return DiskImageResult(imagePath: finalPath, sizeBytes: finalSize, volumeLabel: safeLabel)
    }

    // MARK: - Helpers

    private static func directorySizeKB(at url: URL) throws -> Int {
        let output = try Shell.run("/usr/bin/du", ["-sk", url.path])
        let firstField = output.split(whereSeparator: { $0 == "\t" || $0 == " " }).first
        guard let firstField, let kb = Int(firstField) else {
            throw MBRImageError.parseFailed("`du -sk` output: \(output)")
        }
        return kb
    }

    private static func mountPointFor(device: String) throws -> String? {
        let info = try Shell.run("/usr/sbin/diskutil", ["info", device])
        for line in info.split(separator: "\n") {
            if line.contains("Mount Point:") {
                let value = line.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces)
                if let value, !value.isEmpty, value != "Not applicable (no file system)" {
                    return value
                }
            }
        }
        return nil
    }

    private static func removeExcludedEntries(at root: URL, patterns: [String]) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { return }
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            let matches = patterns.contains { fnmatch($0, name, 0) == 0 }
            if matches {
                try? fm.removeItem(at: url)
                enumerator.skipDescendants()
            }
        }
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
}
