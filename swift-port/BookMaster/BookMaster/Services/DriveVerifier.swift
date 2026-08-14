import Foundation

/// One track carrying ID3 content that doesn't match what
/// Track.update_mp3_tags() is known to write -- either a frame the app
/// never writes (untouched source metadata, an encoder's own tag like
/// ffmpeg's TSSE, a stray ID3v1 trailer), or one of its own frames
/// (title/author/obfuscated ISBN) holding a value that doesn't match
/// this drive. See DriveVerifier.scanForID3TagIssues.
public struct ID3TagIssue: Equatable {
    public let fileName: String
    public let reason: String
}

public struct VerificationResult: Equatable {
    public let detectedSKU: String?
    public let detectedISBN: String?
    public let trackCount: Int
    public let stickUsedMib: Double?
    public let tracksSizeMib: Double?
    public let readSpeedMibS: Double?
    public let expectedDurationSeconds: Int?
    public let encodingKbps: Double?
    public let encodingRateAnomaly: Bool
    public let foundArtifactCount: Int
    public let foundArtifactSamples: [String]
    public let id3TagIssues: [ID3TagIssue]
    public let validationErrors: [String]

    public var isValid: Bool { validationErrors.isEmpty }

    /// A warning, not a validation failure -- a genuinely mismatched or
    /// foreign ID3 tag doesn't make a master unreadable, but it's worth
    /// a human's attention (stale metadata from a re-encode, or a track
    /// that slipped in from a different book). Surfaced, not
    /// auto-stripped the way stray macOS artifacts are.
    public var hasID3TagIssues: Bool { !id3TagIssues.isEmpty }
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

    /// `dryRun: true` only scans and reports what it finds -- used by
    /// verify()/"Check Master", which should never mutate the drive it's
    /// reporting on. The real deletion (`dryRun: false`) is reserved for
    /// an explicit, opt-in "Fix Master" action (see MasterFixer).
    @discardableResult
    static func removeUnexpectedEntries(at mountPoint: URL, dryRun: Bool = false, sampleLimit: Int = 10) -> (found: Int, removed: Int, samples: [String]) {
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
            guard !dryRun else { continue }
            // removeItem resolves the given path directly rather than
            // going through a directory listing, so it works fine even
            // for "._*" files FileManager can't list.
            let url = root.appendingPathComponent(rel)
            if (try? fm.removeItem(at: url)) != nil { removed += 1 }
        }
        return (roots.count, removed, samples)
    }

    // MARK: - ID3 tag verification
    //
    // voxmaster's Track.update_mp3_tags() (see track.py) deliberately
    // deletes whatever ID3 tag a track arrives with and writes its own:
    // TALB=title, TPE1=author, TIT2=a per-track name, and a TXXX:ID
    // frame holding a base64url-obfuscated ISBN. A correctly-processed
    // master's tracks are therefore *expected* to carry ID3 tags --
    // flagging their mere presence would false-positive on every good
    // master. What's actually worth catching is a track still carrying
    // something else: a frame the app never writes (stale source
    // metadata, an encoder's own tag, a stray ID3v1 trailer -- the app
    // only ever writes v2), or one of its own frames holding a value
    // that doesn't match this drive.

    /// `isbn` is this drive's own detected ISBN (from bookInfo/id.txt),
    /// used to catch a TXXX:ID frame whose decoded ISBN doesn't match --
    /// e.g. a track that slipped in from a different book's processed
    /// folder. Title/author are checked against the book catalog entry
    /// for that same ISBN, when one exists.
    static func scanForID3TagIssues(tracksPath: URL, isbn: String?, sampleLimit: Int = 10) -> [ID3TagIssue] {
        let catalogRow = isbn.flatMap { BooksCatalog.lookup(isbn: $0) }
        let expectedTitle = normalizedForComparison(catalogRow?["Title"])
        let expectedAuthor = normalizedForComparison(catalogRow?["Author"])

        var issues: [ID3TagIssue] = []
        for file in AudioProfiler.candidateFiles(in: tracksPath) {
            guard issues.count < sampleLimit else { break }
            let name = file.lastPathComponent

            if ID3Tag.hasID3v1Trailer(at: file) {
                issues.append(ID3TagIssue(fileName: name, reason: "carries an ID3v1 tag (never written by this app)"))
            }

            for frame in ID3Tag.readID3v2Frames(at: file) {
                guard ID3Tag.knownFrameIDs.contains(frame.id) else {
                    issues.append(ID3TagIssue(fileName: name, reason: "unexpected tag frame \(frame.id)"))
                    continue
                }
                switch frame.id {
                case "TXXX:ID":
                    let decoded = ID3Tag.decodeObfuscatedISBN(frame.text)
                    if let isbn, decoded != isbn {
                        issues.append(ID3TagIssue(
                            fileName: name,
                            reason: "ISBN tag mismatch (tag decodes to \(decoded ?? "unreadable"), drive is \(isbn))"
                        ))
                    }
                case "TALB":
                    if let expectedTitle, normalizedForComparison(frame.text) != expectedTitle {
                        issues.append(ID3TagIssue(fileName: name, reason: "title tag mismatch (tag says \"\(frame.text)\")"))
                    }
                case "TPE1":
                    if let expectedAuthor, normalizedForComparison(frame.text) != expectedAuthor {
                        issues.append(ID3TagIssue(fileName: name, reason: "author tag mismatch (tag says \"\(frame.text)\")"))
                    }
                default:
                    break
                }
            }
        }
        return issues
    }

    private static func normalizedForComparison(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        return trimmed.isEmpty ? nil : trimmed
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
        // Scan-only (dryRun: true) -- verify()/"Check Master" reports what
        // it finds and never mutates the drive it's checking. Actually
        // removing anything is the explicit, opt-in "Fix Master" action
        // (see MasterFixer.removeArtifacts).
        log("Checking for unexpected macOS artifacts...")
        let (found, _, samples) = removeUnexpectedEntries(at: mountPoint, dryRun: true)
        if found > 0 {
            log("Found \(found) unexpected artifact root(s): \(samples.joined(separator: ", "))")
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
        var tracksSizeMib: Double?
        var id3Issues: [ID3TagIssue] = []
        if hasTracksDir {
            log("Inspecting audio content (\(deepAudioInspect ? "full scan" : "quick estimate"))...")
            let profile = await AudioProfiler.inspectTracksAudioProfile(tracksPath: tracksPath, fullScan: deepAudioInspect)
            expectedSeconds = profile.durationSeconds
            encodingKbps = profile.averageKbps
            let (totalBytes, _) = AudioProfiler.measureTrackAudioBytes(tracksPath: tracksPath)
            tracksSizeMib = (Double(totalBytes) / 1024.0 / 1024.0 * 10).rounded() / 10

            log("Checking ID3 tags against expected title/author/ISBN...")
            id3Issues = scanForID3TagIssues(tracksPath: tracksPath, isbn: isbn)
            if !id3Issues.isEmpty {
                let detail = id3Issues.map { "\($0.fileName) (\($0.reason))" }.joined(separator: "; ")
                log("\u{26A0}\u{FE0F} ID3 tag issues found on \(id3Issues.count) track file(s): \(detail)")
            } else {
                log("No unexpected ID3 tag content found.")
            }
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
            tracksSizeMib: tracksSizeMib, readSpeedMibS: readSpeed, expectedDurationSeconds: expectedSeconds,
            encodingKbps: encodingKbps, encodingRateAnomaly: rateAnomaly,
            foundArtifactCount: found, foundArtifactSamples: samples, id3TagIssues: id3Issues,
            validationErrors: validationErrors
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
