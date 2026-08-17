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

/// The first track's own ID3 frames, formatted for display -- lets the
/// Verify tab show a concrete example of what's actually written to the
/// disc (e.g. "Title: ...", "Author: ...") instead of just "OK", since
/// "OK" alone doesn't say *what* ended up in the tags.
public struct ID3TagSample: Equatable {
    public let fileName: String
    public let title: String?
    public let author: String?
    public let trackName: String?
    public let isbn: String?
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
    /// nil when the Metadata check wasn't part of this run -- see
    /// silenceIssues below. Distinct from an empty array, which means
    /// it ran and found no ID3 issues.
    public let id3TagIssues: [ID3TagIssue]?
    /// nil when the Metadata check wasn't part of this run, same as
    /// id3TagIssues above.
    public let firstTrackTagSample: ID3TagSample?
    /// nil when the Silence check wasn't part of this run (unchecked in
    /// the Checks panel, or a "check on mount" fast-only pass) --
    /// distinct from an empty array, which means it ran and found none.
    public let silenceIssues: [TrackAudioIssue]?
    public let loudnessIssues: [TrackAudioIssue]?
    public let frameErrorIssues: [TrackAudioIssue]?
    public let validationErrors: [String]

    public var isValid: Bool { validationErrors.isEmpty }

    /// A warning, not a validation failure -- a genuinely mismatched or
    /// foreign ID3 tag doesn't make a master unreadable, but it's worth
    /// a human's attention (stale metadata from a re-encode, or a track
    /// that slipped in from a different book). Surfaced, not
    /// auto-stripped the way stray macOS artifacts are.
    public var hasID3TagIssues: Bool { !(id3TagIssues ?? []).isEmpty }
    public var hasSilenceIssues: Bool { !(silenceIssues ?? []).isEmpty }
    public var hasLoudnessIssues: Bool { !(loudnessIssues ?? []).isEmpty }
    public var hasFrameErrorIssues: Bool { !(frameErrorIssues ?? []).isEmpty }

    /// Folds a fresh run into whatever's already known, so running one
    /// check at a time (or "check on mount"'s fast-only passes) builds
    /// up a fuller picture instead of each run blanking out results
    /// from checks it didn't itself include. Per-check fields (id3/
    /// silence/loudness/frameErrors) keep the previous value when the
    /// new run left them nil; every field backed by a check that always
    /// runs regardless of `checks` (identity, artifacts, audio profile,
    /// which is why they're non-optional here) always takes the new
    /// run's value, since that's genuinely fresher.
    public static func merged(previous: VerificationResult?, new: VerificationResult) -> VerificationResult {
        guard let previous else { return new }
        return VerificationResult(
            detectedSKU: new.detectedSKU, detectedISBN: new.detectedISBN, trackCount: new.trackCount,
            stickUsedMib: new.stickUsedMib, tracksSizeMib: new.tracksSizeMib,
            readSpeedMibS: new.readSpeedMibS ?? previous.readSpeedMibS,
            expectedDurationSeconds: new.expectedDurationSeconds, encodingKbps: new.encodingKbps,
            encodingRateAnomaly: new.encodingRateAnomaly, foundArtifactCount: new.foundArtifactCount,
            foundArtifactSamples: new.foundArtifactSamples,
            id3TagIssues: new.id3TagIssues ?? previous.id3TagIssues,
            firstTrackTagSample: new.firstTrackTagSample ?? previous.firstTrackTagSample,
            silenceIssues: new.silenceIssues ?? previous.silenceIssues,
            loudnessIssues: new.loudnessIssues ?? previous.loudnessIssues,
            frameErrorIssues: new.frameErrorIssues ?? previous.frameErrorIssues,
            validationErrors: new.validationErrors
        )
    }
}

/// Live status of one named check within a verify() run -- drives the
/// Checks panel's per-test indicator (idle outline -> solid running ->
/// solid pass/fail). `issueCount` is 0 for a check like Speed that
/// doesn't itemize per-file issues, so `.failed` there just means the
/// probe itself didn't return a value.
public enum CheckRunStatus: Equatable {
    case running
    case passed
    case failed(issueCount: Int)
}

/// Which of the Verify tab's named checks to run -- mirrors the
/// Python UI's "Silence"/"Loudness"/"Metadata"/"Frames"/"Speed"
/// checkboxes (main_window.py's available_tests) one-to-one, so
/// Settings.usbDriveTests (a comma string of those same names) maps
/// straight onto this OptionSet.
///
/// .fast vs .slow reflects actual cost, not the Python grouping (there
/// wasn't one): metadata is a cheap ID3-header read and speed is a
/// fixed ~256 MiB raw-device read, both roughly constant time
/// regardless of track count. Silence/loudness/frames each fully
/// decode every track via ffmpeg, so they scale with total audio
/// duration -- minutes, not seconds, for a full audiobook.
public struct DriveCheckOptions: OptionSet {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let metadata = DriveCheckOptions(rawValue: 1 << 0)
    public static let speed = DriveCheckOptions(rawValue: 1 << 1)
    public static let silence = DriveCheckOptions(rawValue: 1 << 2)
    public static let loudness = DriveCheckOptions(rawValue: 1 << 3)
    public static let frames = DriveCheckOptions(rawValue: 1 << 4)

    public static let fast: DriveCheckOptions = [.metadata, .speed]
    public static let slow: DriveCheckOptions = [.silence, .loudness, .frames]
    public static let all: DriveCheckOptions = [.metadata, .speed, .silence, .loudness, .frames]

    /// Every check as its own single-flag value, paired with the exact
    /// name used in Settings.usbDriveTests and shown in the Checks
    /// panel -- the one place that spells these names, so the panel's
    /// per-check status indicators can key off `displayName` instead of
    /// a second hand-maintained switch.
    public static let allSingle: [DriveCheckOptions] = [.metadata, .speed, .silence, .loudness, .frames]

    public var displayName: String? {
        switch self {
        case .metadata: return "Metadata"
        case .speed: return "Speed"
        case .silence: return "Silence"
        case .loudness: return "Loudness"
        case .frames: return "Frames"
        default: return nil
        }
    }

    /// Round-trips Settings.usbDriveTests's comma-separated string
    /// ("Silence,Loudness,...") into the equivalent option set.
    public init(commaSeparatedNames: String) {
        let names = Set(commaSeparatedNames.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
        var options: DriveCheckOptions = []
        for option in DriveCheckOptions.allSingle where names.contains(option.displayName?.lowercased() ?? "") {
            options.insert(option)
        }
        self = options
    }
}

public enum DriveVerifierError: Error, CustomStringConvertible {
    /// Carries the fully-computed VerificationResult alongside the
    /// identity errors -- every other check (artifacts, track count,
    /// audio profile, ID3 tags, read speed) already ran and completed
    /// before identity was found to be missing/invalid, so a caller
    /// that only reads `errors` and discards the result would be
    /// throwing away everything else this run found.
    case verificationFailed([String], VerificationResult)
    case readProbeFailed(String)

    public var description: String {
        switch self {
        case .verificationFailed(let errors, _): return errors.joined(separator: "; ")
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

    /// The first candidate file's own ID3 frames, formatted for
    /// display -- see ID3TagSample. nil if there's no track, or the
    /// first track has no ID3v2 tag at all (which scanForID3TagIssues
    /// above would itself have nothing to say about, since an absent
    /// tag isn't one of the "carries something unexpected" cases it
    /// looks for).
    static func sampleFirstTrackTags(tracksPath: URL) -> ID3TagSample? {
        guard let file = AudioProfiler.candidateFiles(in: tracksPath).first else { return nil }
        let frames = ID3Tag.readID3v2Frames(at: file)
        guard !frames.isEmpty else { return nil }
        func text(_ id: String) -> String? { frames.first { $0.id == id }?.text }
        let isbn = text("TXXX:ID").flatMap(ID3Tag.decodeObfuscatedISBN)
        return ID3TagSample(fileName: file.lastPathComponent, title: text("TALB"), author: text("TPE1"), trackName: text("TIT2"), isbn: isbn)
    }

    // MARK: - Silence / Loudness / Frame-error verification (ports
    // track.py's Track.status: analyze_track's per-file ffmpeg checks,
    // gated by DriveCheckOptions rather than always running.)

    /// `log` fires once per file, before that file's ffmpeg pass starts
    /// -- each of these decodes the whole track, so without a
    /// per-file heartbeat a multi-track scan goes silent for however
    /// long the full book takes to decode, which reads as "stuck" (see
    /// the Checks panel's "Slow" grouping).
    ///
    /// `progress` fires after each file completes with (doneCount,
    /// totalCount), so a caller can render a fraction rather than a
    /// single running/done flip -- without it, the panel's status dot
    /// has no way to know a 1-of-12 pass looks any different from an
    /// 11-of-12 one and visually "completes" the moment the first file
    /// finishes.
    ///
    /// Checks `Task.isCancelled` once per file and stops early
    /// (returning whatever was found so far) rather than mid-decode --
    /// cancelling can't interrupt an in-flight ffmpeg subprocess, only
    /// stop the *next* one from starting. `verify()` still throws
    /// CancellationError right after this returns, so a cancelled run
    /// never reports a false pass/fail for a check it didn't finish.
    static func scanForSilence(
        files: [URL], ffmpegPath: String, log: (String) -> Void = { _ in }, progress: (Int, Int) -> Void = { _, _ in }
    ) -> [TrackAudioIssue] {
        var issues: [TrackAudioIssue] = []
        for (index, file) in files.enumerated() {
            guard !Task.isCancelled else { break }
            log("Silence: track \(index + 1)/\(files.count) (\(file.lastPathComponent))\u{2026}")
            let silences = AudioAnalysis.detectSilence(file: file, ffmpegPath: ffmpegPath)
            if !silences.isEmpty {
                issues.append(TrackAudioIssue(fileName: file.lastPathComponent, reason: "\(silences.count) silence period(s) detected"))
            }
            progress(index + 1, files.count)
        }
        return issues
    }

    static func scanForLoudness(
        files: [URL], targetLufs: Double, tolerancePercent: Double = 5.0, ffmpegPath: String,
        log: (String) -> Void = { _ in }, progress: (Int, Int) -> Void = { _, _ in }
    ) -> [TrackAudioIssue] {
        var issues: [TrackAudioIssue] = []
        for (index, file) in files.enumerated() {
            guard !Task.isCancelled else { break }
            log("Loudness: track \(index + 1)/\(files.count) (\(file.lastPathComponent))\u{2026}")
            let measurement = AudioAnalysis.analyzeLoudness(file: file, targetLufs: targetLufs, ffmpegPath: ffmpegPath)
            if !AudioAnalysis.loudnessIsCloseToTarget(measurement, targetLufs: targetLufs, tolerancePercent: tolerancePercent) {
                let measured = measurement?.inputIntegrated.map { "\($0)" } ?? "unmeasured"
                issues.append(TrackAudioIssue(
                    fileName: file.lastPathComponent,
                    reason: "loudness \(measured) LUFS vs target \(targetLufs) LUFS (\u{00B1}\(tolerancePercent.formatted())% tolerance)"
                ))
            }
            progress(index + 1, files.count)
        }
        return issues
    }

    /// Combines `scanForSilence` and `scanForLoudness` into one ffmpeg
    /// pass per file via AudioAnalysis.analyzeLoudnessAndSilence --
    /// used when both checks are selected together (the common case:
    /// DriveCheckOptions.slow/.all) so a multi-track scan doesn't
    /// decode every file twice.
    static func scanForSilenceAndLoudness(
        files: [URL], targetLufs: Double, tolerancePercent: Double = 5.0, ffmpegPath: String,
        log: (String) -> Void = { _ in }, progress: (Int, Int) -> Void = { _, _ in }
    ) -> (silence: [TrackAudioIssue], loudness: [TrackAudioIssue]) {
        var silenceIssues: [TrackAudioIssue] = []
        var loudnessIssues: [TrackAudioIssue] = []
        for (index, file) in files.enumerated() {
            guard !Task.isCancelled else { break }
            log("Silence/Loudness: track \(index + 1)/\(files.count) (\(file.lastPathComponent))\u{2026}")
            let (measurement, silences) = AudioAnalysis.analyzeLoudnessAndSilence(
                file: file, targetLufs: targetLufs, ffmpegPath: ffmpegPath
            )
            if !silences.isEmpty {
                silenceIssues.append(TrackAudioIssue(fileName: file.lastPathComponent, reason: "\(silences.count) silence period(s) detected"))
            }
            if !AudioAnalysis.loudnessIsCloseToTarget(measurement, targetLufs: targetLufs, tolerancePercent: tolerancePercent) {
                let measured = measurement?.inputIntegrated.map { "\($0)" } ?? "unmeasured"
                loudnessIssues.append(TrackAudioIssue(
                    fileName: file.lastPathComponent,
                    reason: "loudness \(measured) LUFS vs target \(targetLufs) LUFS (\u{00B1}\(tolerancePercent.formatted())% tolerance)"
                ))
            }
            progress(index + 1, files.count)
        }
        return (silenceIssues, loudnessIssues)
    }

    /// Runs AudioAnalysis.checkFrames' four sub-checks per file and
    /// turns whichever ones failed into a readable reason -- a file can
    /// fail more than one at once (e.g. a truncated file both fails to
    /// decode and lacks real audio parameters), so this reports all of
    /// them rather than just the first.
    static func scanForFrameErrors(
        files: [URL], ffmpegPath: String, ffprobePath: String,
        log: (String) -> Void = { _ in }, progress: (Int, Int) -> Void = { _, _ in }
    ) -> [TrackAudioIssue] {
        var issues: [TrackAudioIssue] = []
        for (index, file) in files.enumerated() {
            guard !Task.isCancelled else { break }
            log("Frames: track \(index + 1)/\(files.count) (\(file.lastPathComponent))\u{2026}")
            let result = AudioAnalysis.checkFrames(file: file, ffmpegPath: ffmpegPath, ffprobePath: ffprobePath)
            if let reason = frameIssueReason(for: result) {
                issues.append(TrackAudioIssue(fileName: file.lastPathComponent, reason: reason))
            }
            progress(index + 1, files.count)
        }
        return issues
    }

    /// Combines scanForSilenceAndLoudness with the Frames check's
    /// decode-error scan into one ffmpeg pass per file via
    /// AudioAnalysis.analyzeTrack -- used when silence, loudness, and
    /// frames are all selected together (DriveCheckOptions.slow/.all,
    /// the common case), so a track is decoded once instead of twice.
    /// ffprobe's codec/parameter check and the raw header-byte check
    /// still run per file -- those are cheap container/byte-level
    /// lookups, not full decodes, so there's nothing to gain by folding
    /// them into the ffmpeg pass too.
    static func scanForSilenceLoudnessAndFrames(
        files: [URL], targetLufs: Double, tolerancePercent: Double = 10.0, ffmpegPath: String, ffprobePath: String,
        log: (String) -> Void = { _ in }, progress: (Int, Int) -> Void = { _, _ in }
    ) -> (silence: [TrackAudioIssue], loudness: [TrackAudioIssue], frames: [TrackAudioIssue]) {
        var silenceIssues: [TrackAudioIssue] = []
        var loudnessIssues: [TrackAudioIssue] = []
        var frameIssues: [TrackAudioIssue] = []
        for (index, file) in files.enumerated() {
            guard !Task.isCancelled else { break }
            log("Silence/Loudness/Frames: track \(index + 1)/\(files.count) (\(file.lastPathComponent))\u{2026}")
            let (measurement, silences, decodeErrorCount) = AudioAnalysis.analyzeTrack(
                file: file, targetLufs: targetLufs, ffmpegPath: ffmpegPath
            )
            if !silences.isEmpty {
                silenceIssues.append(TrackAudioIssue(fileName: file.lastPathComponent, reason: "\(silences.count) silence period(s) detected"))
            }
            if !AudioAnalysis.loudnessIsCloseToTarget(measurement, targetLufs: targetLufs, tolerancePercent: tolerancePercent) {
                let measured = measurement?.inputIntegrated.map { "\($0)" } ?? "unmeasured"
                loudnessIssues.append(TrackAudioIssue(
                    fileName: file.lastPathComponent,
                    reason: "loudness \(measured) LUFS vs target \(targetLufs) LUFS (\u{00B1}\(tolerancePercent.formatted())% tolerance)"
                ))
            }
            let frameResult = AudioAnalysis.checkFrames(decodeErrorCount: decodeErrorCount, file: file, ffprobePath: ffprobePath)
            if let reason = frameIssueReason(for: frameResult) {
                frameIssues.append(TrackAudioIssue(fileName: file.lastPathComponent, reason: reason))
            }
            progress(index + 1, files.count)
        }
        return (silenceIssues, loudnessIssues, frameIssues)
    }

    /// nil when the file passed every Frames sub-check; otherwise the
    /// failed ones joined into one reason -- shared by scanForFrameErrors
    /// and scanForSilenceLoudnessAndFrames so the two code paths report
    /// issues identically regardless of which ffmpeg pass produced them.
    private static func frameIssueReason(for result: AudioAnalysis.FrameCheckResult) -> String? {
        guard !result.isValid else { return nil }
        var reasons: [String] = []
        if !result.identifiesAsMP3 { reasons.append("does not identify as MP3") }
        if !result.hasAudioParameters { reasons.append("no valid audio parameters") }
        if result.decodeErrorCount < 0 {
            reasons.append("ffmpeg could not decode the file")
        } else if result.decodeErrorCount > 0 {
            reasons.append("\(result.decodeErrorCount) frame error(s)")
        }
        if !result.startsWithValidHeader { reasons.append("missing ID3/MPEG sync header") }
        return reasons.joined(separator: "; ")
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
        checks: DriveCheckOptions = .all,
        deepAudioInspect: Bool = true,
        loudnessTolerancePercent: Double = 10.0,
        minReadSpeedMibS: Double = 5.0,
        config: AppConfig = ConfigStore.shared,
        productionLog: ProductionLog? = nil,
        serial: String? = nil,
        vid: String? = nil,
        pid: String? = nil,
        log: @escaping (String) -> Void = { _ in },
        checkStatus: @escaping (DriveCheckOptions, CheckRunStatus) -> Void = { _, _ in },
        checkProgress: @escaping (DriveCheckOptions, Int, Int) -> Void = { _, _, _ in }
    ) async throws -> VerificationResult {
        try Task.checkCancellation()

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
        if checks.contains(.speed), let rawDevicePath {
            checkStatus(.speed, .running)
            log("Running read-speed probe (\(readMib) MiB, minimum \(minReadSpeedMibS) MiB/s)...")
            readSpeed = try? probeReadSpeed(rawDevicePath: rawDevicePath, readMib: readMib)
            // Previously this only checked whether the probe itself ran
            // (readSpeed != nil) -- a measured-but-slow drive silently
            // passed. Now a measured speed below minReadSpeedMibS fails
            // the check too, same as a probe that couldn't run at all.
            let meetsMinimum = (readSpeed ?? 0) >= minReadSpeedMibS
            if let readSpeed {
                log(meetsMinimum
                    ? "Read speed \(readSpeed) MiB/s."
                    : "\u{26A0}\u{FE0F} Read speed \(readSpeed) MiB/s is below the \(minReadSpeedMibS) MiB/s minimum.")
            }
            checkStatus(.speed, meetsMinimum ? .passed : .failed(issueCount: 0))
            try Task.checkCancellation()
        }

        var expectedSeconds: Int?
        var encodingKbps: Double?
        var tracksSizeMib: Double?
        var id3Issues: [ID3TagIssue]?
        var tagSample: ID3TagSample?
        var silenceIssues: [TrackAudioIssue]?
        var loudnessIssues: [TrackAudioIssue]?
        var frameErrorIssues: [TrackAudioIssue]?
        if hasTracksDir {
            log("Inspecting audio content (\(deepAudioInspect ? "full scan" : "quick estimate"))...")
            let profile = await AudioProfiler.inspectTracksAudioProfile(tracksPath: tracksPath, fullScan: deepAudioInspect)
            expectedSeconds = profile.durationSeconds
            encodingKbps = profile.averageKbps
            let (totalBytes, _) = AudioProfiler.measureTrackAudioBytes(tracksPath: tracksPath)
            tracksSizeMib = (Double(totalBytes) / 1024.0 / 1024.0 * 10).rounded() / 10

            if checks.contains(.metadata) {
                checkStatus(.metadata, .running)
                log("Checking ID3 tags against expected title/author/ISBN...")
                let found = scanForID3TagIssues(tracksPath: tracksPath, isbn: isbn)
                id3Issues = found
                tagSample = sampleFirstTrackTags(tracksPath: tracksPath)
                if !found.isEmpty {
                    let detail = found.map { "\($0.fileName) (\($0.reason))" }.joined(separator: "; ")
                    log("\u{26A0}\u{FE0F} ID3 tag issues found on \(found.count) track file(s): \(detail)")
                } else {
                    log("No unexpected ID3 tag content found.")
                }
                checkStatus(.metadata, found.isEmpty ? .passed : .failed(issueCount: found.count))
                try Task.checkCancellation()
            }

            if !checks.isDisjoint(with: [.silence, .loudness, .frames]), let ffmpegPath = FFmpegEncoder.locateFFmpeg() {
                let files = AudioProfiler.candidateFiles(in: tracksPath)
                let ffprobePath = checks.contains(.frames) ? FFmpegEncoder.locateFFprobe() : nil

                if checks.contains(.silence), checks.contains(.loudness), checks.contains(.frames), let ffprobePath {
                    checkStatus(.silence, .running)
                    checkStatus(.loudness, .running)
                    checkStatus(.frames, .running)
                    log("Checking \(files.count) track(s) for silence, loudness (target \(config.encoding.targetLufs) LUFS \u{00B1}\(loudnessTolerancePercent.formatted())%), and frame/header integrity...")
                    let (foundSilence, foundLoudness, foundFrames) = scanForSilenceLoudnessAndFrames(
                        files: files, targetLufs: config.encoding.targetLufs, tolerancePercent: loudnessTolerancePercent,
                        ffmpegPath: ffmpegPath, ffprobePath: ffprobePath, log: log
                    ) { done, total in
                        checkProgress(.silence, done, total)
                        checkProgress(.loudness, done, total)
                        checkProgress(.frames, done, total)
                    }
                    silenceIssues = foundSilence
                    loudnessIssues = foundLoudness
                    frameErrorIssues = foundFrames
                    log(foundSilence.isEmpty ? "No silence found." : "\u{26A0}\u{FE0F} Silence found on \(foundSilence.count) track file(s).")
                    checkStatus(.silence, foundSilence.isEmpty ? .passed : .failed(issueCount: foundSilence.count))
                    log(foundLoudness.isEmpty ? "Loudness within target on all tracks." : "\u{26A0}\u{FE0F} Loudness issues on \(foundLoudness.count) track file(s).")
                    checkStatus(.loudness, foundLoudness.isEmpty ? .passed : .failed(issueCount: foundLoudness.count))
                    log(foundFrames.isEmpty ? "No frame errors found." : "\u{26A0}\u{FE0F} Frame errors on \(foundFrames.count) track file(s).")
                    checkStatus(.frames, foundFrames.isEmpty ? .passed : .failed(issueCount: foundFrames.count))
                    try Task.checkCancellation()
                } else {
                    if checks.contains(.silence) && checks.contains(.loudness) {
                        checkStatus(.silence, .running)
                        checkStatus(.loudness, .running)
                        log("Checking \(files.count) track(s) for silence and loudness (target \(config.encoding.targetLufs) LUFS \u{00B1}\(loudnessTolerancePercent.formatted())%)...")
                        let (foundSilence, foundLoudness) = scanForSilenceAndLoudness(
                            files: files, targetLufs: config.encoding.targetLufs, tolerancePercent: loudnessTolerancePercent,
                            ffmpegPath: ffmpegPath, log: log
                        ) { done, total in
                            checkProgress(.silence, done, total)
                            checkProgress(.loudness, done, total)
                        }
                        silenceIssues = foundSilence
                        loudnessIssues = foundLoudness
                        log(foundSilence.isEmpty ? "No silence found." : "\u{26A0}\u{FE0F} Silence found on \(foundSilence.count) track file(s).")
                        checkStatus(.silence, foundSilence.isEmpty ? .passed : .failed(issueCount: foundSilence.count))
                        log(foundLoudness.isEmpty ? "Loudness within target on all tracks." : "\u{26A0}\u{FE0F} Loudness issues on \(foundLoudness.count) track file(s).")
                        checkStatus(.loudness, foundLoudness.isEmpty ? .passed : .failed(issueCount: foundLoudness.count))
                        try Task.checkCancellation()
                    } else {
                        if checks.contains(.silence) {
                            checkStatus(.silence, .running)
                            log("Checking \(files.count) track(s) for silence...")
                            let found = scanForSilence(files: files, ffmpegPath: ffmpegPath, log: log) { done, total in
                                checkProgress(.silence, done, total)
                            }
                            silenceIssues = found
                            log(found.isEmpty ? "No silence found." : "\u{26A0}\u{FE0F} Silence found on \(found.count) track file(s).")
                            checkStatus(.silence, found.isEmpty ? .passed : .failed(issueCount: found.count))
                            try Task.checkCancellation()
                        }
                        if checks.contains(.loudness) {
                            checkStatus(.loudness, .running)
                            log("Checking \(files.count) track(s) for loudness (target \(config.encoding.targetLufs) LUFS \u{00B1}\(loudnessTolerancePercent.formatted())%)...")
                            let found = scanForLoudness(
                                files: files, targetLufs: config.encoding.targetLufs, tolerancePercent: loudnessTolerancePercent,
                                ffmpegPath: ffmpegPath, log: log
                            ) { done, total in
                                checkProgress(.loudness, done, total)
                            }
                            loudnessIssues = found
                            log(found.isEmpty ? "Loudness within target on all tracks." : "\u{26A0}\u{FE0F} Loudness issues on \(found.count) track file(s).")
                            checkStatus(.loudness, found.isEmpty ? .passed : .failed(issueCount: found.count))
                            try Task.checkCancellation()
                        }
                    }
                    if checks.contains(.frames) {
                        if let ffprobePath {
                            checkStatus(.frames, .running)
                            log("Checking \(files.count) track(s) for frame/header integrity...")
                            let found = scanForFrameErrors(files: files, ffmpegPath: ffmpegPath, ffprobePath: ffprobePath, log: log) { done, total in
                                checkProgress(.frames, done, total)
                            }
                            frameErrorIssues = found
                            log(found.isEmpty ? "No frame errors found." : "\u{26A0}\u{FE0F} Frame errors on \(found.count) track file(s).")
                            checkStatus(.frames, found.isEmpty ? .passed : .failed(issueCount: found.count))
                            try Task.checkCancellation()
                        } else {
                            log("Skipping Frames check: ffprobe not found.")
                        }
                    }
                }
            }
        }
        let rateAnomaly = encodingKbps.map { abs($0 - expectedBitRateBPS / 1000.0) > 0.5 } ?? false

        if let productionLog, let sku, validationErrors.isEmpty {
            try? productionLog.recordVerification(
                sku: sku, serial: serial, isbn: isbn, trackCount: trackCount,
                readMibS: readSpeed, stickUsedMib1dp: stickUsedMib
            )
        }

        // Unlike recordVerification above, this always inserts -- a
        // failed verification (bad SKU/ISBN, missing content) is exactly
        // what "is this master block accurate" needs to capture, not
        // just successes.
        if let productionLog {
            let deviceId = try? productionLog.upsertDevice(vid: vid ?? "", pid: pid ?? "", serial: serial ?? "UNKNOWN")
            try? productionLog.insertMasterVerification(
                deviceId: deviceId, masterWriteId: nil, sku: sku, detectedSku: sku, detectedIsbn: isbn,
                trackCount: trackCount, stickUsedMib: stickUsedMib, tracksSizeMib: tracksSizeMib,
                readSpeedMibS: readSpeed, expectedDurationS: expectedSeconds, encodingKbps: encodingKbps,
                encodingRateAnomaly: rateAnomaly, foundArtifactCount: found, id3IssueCount: (id3Issues ?? []).count,
                validationErrors: validationErrors, passed: validationErrors.isEmpty
            )
        }

        let result = VerificationResult(
            detectedSKU: sku, detectedISBN: isbn, trackCount: trackCount, stickUsedMib: stickUsedMib,
            tracksSizeMib: tracksSizeMib, readSpeedMibS: readSpeed, expectedDurationSeconds: expectedSeconds,
            encodingKbps: encodingKbps, encodingRateAnomaly: rateAnomaly,
            foundArtifactCount: found, foundArtifactSamples: samples, id3TagIssues: id3Issues,
            firstTrackTagSample: tagSample,
            silenceIssues: silenceIssues, loudnessIssues: loudnessIssues, frameErrorIssues: frameErrorIssues,
            validationErrors: validationErrors
        )

        guard validationErrors.isEmpty else {
            throw DriveVerifierError.verificationFailed(validationErrors, result)
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
