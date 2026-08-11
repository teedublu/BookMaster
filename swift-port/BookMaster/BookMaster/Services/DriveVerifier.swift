import Foundation

public struct VerificationResult: Equatable {
    public let detectedSKU: String?
    public let detectedISBN: String?
    public let trackCount: Int
    public let stickUsedMib: Double?
    public let readSpeedMibS: Double?
    public let expectedDurationSeconds: Int?
    public let encodingKbps: Double?
    public let encodingRateAnomaly: Bool
    public let removedArtifactCount: Int
    public let foundArtifactCount: Int
    public let removedArtifactSamples: [String]
    public let validationErrors: [String]

    public var isValid: Bool { validationErrors.isEmpty }
}

public enum DriveVerifierError: Error, CustomStringConvertible {
    case verificationFailed([String])
    case readProbeFailed(String)

    public var description: String {
        switch self {
        case .verificationFailed(let errors): return errors.joined(separator: "; ")
        case .readProbeFailed(let detail): return "read-speed probe failed: \(detail)"
        }
    }
}

/// Ports verifier.py's verify(): the deep, production-grade
/// verification this app's original "Check Master" (a checksum-only
/// read of bookInfo files -- still available as MasterReader) doesn't
/// come close to. This is the new primary verification path.
///
/// Unlike a build-time checksum check, this operates on a live mounted
/// drive: real read-speed benchmarking, real audio content inspection,
/// and two independent identity signals (SKU parsed from the volume
/// name, ISBN parsed from bookInfo/id.txt) that must both agree.
public enum DriveVerifier {
    private static let expectedBitRateBPS = 96_000.0

    private static let skuHyphenPattern = #"^([A-Z]{2,4})-(\d{4,6})-([A-Z0-9]{2,8})$"#
    private static let skuCompactPattern = #"^([A-Z]{2,4})(\d{4,6})([A-Z0-9]{2,8})$"#
    private static let isbnPattern = #"\b(97[89][0-9\-]{10,20}|[0-9Xx\-]{10,20})\b"#

    private static let unexpectedNames: Set<String> = [
        ".ds_store", ".fseventsd", ".spotlight-v100", ".temporaryitems", ".trashes",
        "$recycle.bin", "system volume information",
    ]

    // MARK: - Identity detection

    static func normalizeVolumeSKU(_ volumeName: String) -> String? {
        let raw = volumeName.trimmingCharacters(in: .whitespaces).uppercased()
        guard !raw.isEmpty else { return nil }

        if let match = firstMatch(pattern: skuHyphenPattern, in: raw), match.count == 4 {
            return "\(match[1])-\(match[2])-\(match[3])"
        }
        let compact = raw.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init)
        let compactStr = String(compact)
        if let match = firstMatch(pattern: skuCompactPattern, in: compactStr), match.count == 4 {
            return "\(match[1])-\(match[2])-\(match[3])"
        }
        return nil
    }

    static func parseISBN(fromIdFileText text: String) -> String? {
        var isbn: String?
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if let kv = firstMatch(pattern: #"^\s*([A-Za-z0-9 _-]+)\s*[:=]\s*(.*?)\s*$"#, in: line), kv.count == 3 {
                let key = kv[1].trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: " ", with: "_")
                let value = kv[2].trimmingCharacters(in: .whitespaces)
                if ["isbn", "isbn13", "isbn_13", "isbn10", "isbn_10"].contains(key), !value.isEmpty {
                    isbn = value
                }
            }
            if isbn == nil, let m = firstMatch(pattern: isbnPattern, in: line), m.count >= 2 {
                isbn = m[1]
            }
        }
        return isbn
    }

    private static func detectIdentity(mountPoint: URL) -> (sku: String?, isbn: String?) {
        let volumeSKU = normalizeVolumeSKU(mountPoint.lastPathComponent)
        var isbn: String?
        let idFile = mountPoint.appendingPathComponent("bookInfo/id.txt")
        if let text = try? String(contentsOf: idFile, encoding: .utf8) {
            isbn = parseISBN(fromIdFileText: text)
        }
        return (volumeSKU, isbn)
    }

    // MARK: - Artifact cleanup (ports _remove_unexpected_entries)

    static func isUnexpectedEntry(_ relativePath: String) -> Bool {
        for part in relativePath.split(separator: "/") {
            let p = part.lowercased()
            if p.hasPrefix("._") { return true }
            if unexpectedNames.contains(p) { return true }
        }
        return false
    }

    @discardableResult
    static func removeUnexpectedEntries(at mountPoint: URL, sampleLimit: Int = 10) -> (found: Int, removed: Int, samples: [String]) {
        let fm = FileManager.default
        // Must canonicalize before walking: firmlink-resolved paths (see
        // URL.canonicalized()) matter here too, since RawDirectoryLister
        // builds child URLs by appending onto whatever root it's given.
        let root = mountPoint.canonicalized()

        // RawDirectoryLister, not FileManager.enumerator: Foundation's
        // directory APIs silently never list "._*" AppleDouble files --
        // confirmed real on a real mounted FAT volume, not just a theory
        // -- and those are exactly the macOS cruft this cleanup exists to
        // catch. See RawDirectoryLister's doc comment.
        let allRelPaths = RawDirectoryLister.allEntriesRecursively(at: root)

        // Roots only: an unexpected directory's own children shouldn't
        // also be counted/removed individually once the directory itself
        // is slated for removal (mirrors the Python version's same
        // dedup, there via a parent/child relationship check).
        var roots: [String] = []
        for rel in allRelPaths.sorted(by: { $0.split(separator: "/").count < $1.split(separator: "/").count }) where isUnexpectedEntry(rel) {
            let alreadyCovered = roots.contains { existing in rel == existing || rel.hasPrefix(existing + "/") }
            if !alreadyCovered { roots.append(rel) }
        }

        var removed = 0
        var samples: [String] = []
        for rel in roots {
            if samples.count < sampleLimit { samples.append(rel) }
            // removeItem resolves the given path directly rather than
            // going through a directory listing, so it works fine even
            // for "._*" files FileManager can't list.
            let url = root.appendingPathComponent(rel)
            if (try? fm.removeItem(at: url)) != nil { removed += 1 }
        }
        return (roots.count, removed, samples)
    }

    // MARK: - Read-speed probe (ports _probe_read_speed)

    /// Reads `readMib` MiB from the raw device via `dd` and returns
    /// MiB/s. NOT run with sudo (unlike voxmaster's `sudo dd`) -- this
    /// app's established pattern (RawDeviceWriter) is to attempt the
    /// direct, unprivileged POSIX/CLI path first and surface whatever
    /// error comes back, rather than assume elevation is required.
    public static func probeReadSpeed(rawDevicePath: String, readMib: Int = 256, blockSizeMib: Int = 4) throws -> Double {
        let count = max(1, readMib / blockSizeMib)
        let start = Date()
        do {
            try Shell.run("/bin/dd", ["if=\(rawDevicePath)", "of=/dev/null", "bs=\(blockSizeMib)m", "count=\(count)", "status=none"])
        } catch let error as ShellError {
            throw DriveVerifierError.readProbeFailed(error.description)
        }
        let elapsed = max(0.001, Date().timeIntervalSince(start))
        return (Double(count * blockSizeMib) / elapsed * 100).rounded() / 100
    }

    // MARK: - Main verification

    public static func verify(
        mountPoint: URL,
        rawDevicePath: String?,
        readMib: Int = 256,
        skipSpeedTest: Bool = false,
        deepAudioInspect: Bool = true,
        productionLog: ProductionLog? = nil,
        serial: String? = nil,
        log: @escaping (String) -> Void = { _ in }
    ) async throws -> VerificationResult {
        log("Checking for unexpected macOS artifacts...")
        let (found, removed, samples) = removeUnexpectedEntries(at: mountPoint)
        if found > 0 {
            log("Removed \(removed)/\(found) unexpected artifact roots: \(samples.joined(separator: ", "))")
        } else {
            log("No unexpected macOS artifacts found.")
        }

        let (sku, isbn) = detectIdentity(mountPoint: mountPoint)

        let tracksPath = mountPoint.appendingPathComponent("tracks")
        let hasTracksDir = FileManager.default.fileExists(atPath: tracksPath.path)
        let trackCount = hasTracksDir ? ((try? FileManager.default.contentsOfDirectory(atPath: tracksPath.path).count) ?? 0) : 0

        var stickUsedMib: Double?
        if let values = try? mountPoint.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]),
           let total = values.volumeTotalCapacity, let available = values.volumeAvailableCapacity {
            stickUsedMib = (Double(total - available) / 1024.0 / 1024.0 * 10).rounded() / 10
        }

        var validationErrors: [String] = []
        if sku == nil { validationErrors.append("SKU missing/invalid in volume name") }
        if isbn == nil { validationErrors.append("ISBN missing in id.txt") }

        var readSpeed: Double?
        if !skipSpeedTest, let rawDevicePath {
            log("Running read-speed probe (\(readMib) MiB)...")
            readSpeed = try? probeReadSpeed(rawDevicePath: rawDevicePath, readMib: readMib)
        }

        var expectedSeconds: Int?
        var encodingKbps: Double?
        if hasTracksDir {
            log("Inspecting audio content (\(deepAudioInspect ? "full scan" : "quick estimate"))...")
            let profile = await AudioProfiler.inspectTracksAudioProfile(tracksPath: tracksPath, fullScan: deepAudioInspect)
            expectedSeconds = profile.durationSeconds
            encodingKbps = profile.averageKbps
        }
        let rateAnomaly = encodingKbps.map { abs($0 - expectedBitRateBPS / 1000.0) > 0.5 } ?? false

        if let productionLog, let sku, validationErrors.isEmpty {
            try? productionLog.recordVerification(
                sku: sku, serial: serial, isbn: isbn, trackCount: trackCount,
                readMibS: readSpeed, stickUsedMib1dp: stickUsedMib
            )
        }

        let result = VerificationResult(
            detectedSKU: sku, detectedISBN: isbn, trackCount: trackCount, stickUsedMib: stickUsedMib,
            readSpeedMibS: readSpeed, expectedDurationSeconds: expectedSeconds, encodingKbps: encodingKbps,
            encodingRateAnomaly: rateAnomaly, removedArtifactCount: removed, foundArtifactCount: found,
            removedArtifactSamples: samples, validationErrors: validationErrors
        )

        guard validationErrors.isEmpty else {
            throw DriveVerifierError.verificationFailed(validationErrors)
        }
        return result
    }

    // MARK: - Regex helper

    private static func firstMatch(pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        var groups: [String] = []
        for i in 0..<match.numberOfRanges {
            guard let r = Range(match.range(at: i), in: text) else { groups.append(""); continue }
            groups.append(String(text[r]))
        }
        return groups
    }
}
