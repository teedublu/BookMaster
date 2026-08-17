import Foundation

public struct TrackFolderStats: Equatable {
    public let fileCount: Int
    public let totalBytes: Int64
}

public struct MasterContentAuditResult: Equatable, Identifiable {
    public var id: String { masterRoot.path }
    public let masterRoot: URL
    public let sku: String
    public let isbn: String?
    /// bookInfo/count.txt -- the track count declared at build time
    /// (distinct from id.txt, which holds the ISBN, not a count).
    public let declaredCount: Int?
    public let masterTracks: TrackFolderStats?
    public let imageTracks: TrackFolderStats?
    public let imageChecked: Bool
    /// bookInfo/checksum.txt vs. a fresh SHA-256 of master/ -- nil if
    /// either side couldn't be read. Catches content that changed
    /// (corruption, a manual edit) after the master was built, which a
    /// file count/size match alone wouldn't reveal.
    public let checksumMatches: Bool?
    public let expectedDurationSeconds: Int?
    public let expectedBitRateBPS: Int
    public let expectedSizeBytes: Int64?
    public let issues: [String]

    public var isClean: Bool { issues.isEmpty }
}

/// Cross-checks a master's on-disk build output (<outputFolder>/<sku>/
/// {master,image}) against what it's supposed to contain, to catch a
/// master that's silently missing content -- a track that failed to
/// encode, a partial copy into the image -- that nothing else
/// currently detects.
///
/// Distinct from DriveVerifier.verify(): that operates on a live
/// mounted USB drive with a full audio-duration decode. This operates
/// on the build output sitting on disk, using cheap file-count/size
/// stats instead of decoding audio, and can optionally also look
/// inside the built .img (mounting it read-only via hdiutil) --
/// gated behind `checkImageContents` since mounting/unmounting a few
/// hundred images in a library scan is meaningfully slow.
public enum MasterContentAuditor {
    /// Recursively finds every master build folder under `directory` --
    /// any directory containing master/bookInfo/id.txt. Does not descend
    /// into a matched folder's own children (a master's tracks/processed/
    /// image subfolders never contain a nested master), so this stays to
    /// filesystem metadata calls rather than walking every track file.
    public static func findMasterRoots(under directory: URL, config: AppConfig = ConfigStore.shared) -> [URL] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: directory.path, isDirectory: &isDir), isDir.boolValue else { return [] }

        let idMarker = directory.appendingPathComponent("master").appendingPathComponent(config.outputStructure.idFile)
        if fm.fileExists(atPath: idMarker.path) {
            return [directory]
        }

        guard let entries = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return []
        }
        var found: [URL] = []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let isEntryDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isEntryDir else { continue }
            found.append(contentsOf: findMasterRoots(under: entry, config: config))
        }
        return found
    }

    /// Audits one master. `masterRoot` is the SKU folder itself (the
    /// parent of `master/` and `image/`), matching what
    /// findMasterRoots returns and what MasterResolver's ResolvedMaster
    /// .imagePath resolves to two path components up.
    public static func audit(
        masterRoot: URL, checkImageContents: Bool, config: AppConfig = ConfigStore.shared,
        log: @escaping (String) -> Void = { _ in }
    ) -> MasterContentAuditResult {
        let masterPath = masterRoot.appendingPathComponent("master")
        let sku = masterRoot.lastPathComponent
        var issues: [String] = []

        let isbn = (try? String(contentsOf: masterPath.appendingPathComponent(config.outputStructure.idFile), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if isbn == nil || isbn?.isEmpty == true {
            issues.append("Missing or unreadable id.txt")
        }

        let declaredCountText = (try? String(contentsOf: masterPath.appendingPathComponent(config.outputStructure.countFile), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let declaredCount = declaredCountText.flatMap { Int($0) }
        if declaredCount == nil {
            issues.append("Missing or unreadable count.txt")
        }

        let masterTracksPath = masterPath.appendingPathComponent(config.outputStructure.tracksPath)
        var masterTracks: TrackFolderStats?
        if FileManager.default.fileExists(atPath: masterTracksPath.path) {
            let (bytes, count) = AudioProfiler.measureTrackAudioBytes(tracksPath: masterTracksPath)
            masterTracks = TrackFolderStats(fileCount: count, totalBytes: bytes)
        } else {
            issues.append("Missing master/tracks folder")
        }

        if let declaredCount, let masterTracks, declaredCount != masterTracks.fileCount {
            issues.append("count.txt says \(declaredCount) but master/tracks has \(masterTracks.fileCount) file(s)")
        }

        // bookInfo/checksum.txt vs. a fresh hash of master/ -- catches
        // content that changed since the master was built (corruption,
        // a manual edit) even when the count still lines up. Checksum
        // itself excludes checksum.txt/version.txt so re-hashing here
        // is safe (see Checksum.swift).
        //
        // Only meaningful for v3+ masters: the old Python builder
        // (Master.checksum in master.py) cached its checksum on first
        // property access, which happened via a debug log line *before*
        // tracks were copied into tracks/ -- so every v2 checksum.txt
        // hashes an empty tracks folder and will never match real
        // content. Skip the check entirely for those rather than flag
        // every legacy master as corrupt.
        let builtVersion = (try? String(contentsOf: masterPath.appendingPathComponent(config.outputStructure.versionFile), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let isV3OrLater = builtVersion.flatMap { Double($0) }.map { $0 >= 3.0 } ?? false

        var checksumMatches: Bool?
        if isV3OrLater {
            let storedChecksum = (try? String(contentsOf: masterPath.appendingPathComponent(config.outputStructure.checksumFile), encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let actualChecksum = try? Checksum.compute(rootDirectory: masterPath)
            if let storedChecksum, !storedChecksum.isEmpty, let actualChecksum {
                checksumMatches = storedChecksum == actualChecksum
                if checksumMatches == false {
                    issues.append("checksum.txt doesn't match a fresh hash of master/ \u{2014} content changed since the master was built")
                }
            } else {
                issues.append("Missing or unreadable checksum.txt")
            }
        }

        var imageTracks: TrackFolderStats?
        if checkImageContents {
            if let imagePath = findImageFile(inMasterRoot: masterRoot) {
                do {
                    imageTracks = try withMountedImage(imagePath, log: log) { mountPoint in
                        let imageTracksPath = mountPoint.appendingPathComponent(config.outputStructure.tracksPath)
                        let (bytes, count) = AudioProfiler.measureTrackAudioBytes(tracksPath: imageTracksPath)
                        log("Read \(count) track file(s), \(bytes) byte(s) from the mounted image.")
                        return TrackFolderStats(fileCount: count, totalBytes: bytes)
                    }
                } catch {
                    issues.append("Could not inspect .img: \(error)")
                    log("Could not inspect .img: \(error)")
                }
            } else {
                issues.append("No .img file found under image/")
                log("No .img file found under \(masterRoot.appendingPathComponent("image").path)")
            }
        }

        if let masterTracks, let imageTracks, masterTracks.fileCount != imageTracks.fileCount {
            issues.append("master/tracks has \(masterTracks.fileCount) file(s) but the image has \(imageTracks.fileCount)")
        }

        let catalogRow = isbn.flatMap { BooksCatalog.lookup(isbn: $0) }
        let expectedDurationSeconds = BooksCatalog.parseDurationSeconds(catalogRow?["Duration"])
        // bit_rate is stored in bits/sec already (config.json's own
        // comment: "without k as comparisons > < are performed").
        let expectedSizeBytes: Int64? = expectedDurationSeconds.map { Int64($0) * Int64(config.encoding.bitRate) / 8 }

        if let expectedSizeBytes, let masterTracks {
            appendSizeIssue(
                label: "master/tracks", actualBytes: masterTracks.totalBytes, expectedBytes: expectedSizeBytes,
                fileCount: masterTracks.fileCount, expectedDurationSeconds: expectedDurationSeconds, into: &issues
            )
        }
        if let expectedSizeBytes, let imageTracks {
            appendSizeIssue(
                label: "image", actualBytes: imageTracks.totalBytes, expectedBytes: expectedSizeBytes,
                fileCount: imageTracks.fileCount, expectedDurationSeconds: expectedDurationSeconds, into: &issues
            )
        }

        return MasterContentAuditResult(
            masterRoot: masterRoot, sku: sku, isbn: isbn, declaredCount: declaredCount,
            masterTracks: masterTracks, imageTracks: imageTracks, imageChecked: checkImageContents,
            checksumMatches: checksumMatches,
            expectedDurationSeconds: expectedDurationSeconds, expectedBitRateBPS: config.encoding.bitRate,
            expectedSizeBytes: expectedSizeBytes, issues: issues
        )
    }

    /// Audits every master under `directory`, one at a time. Reports
    /// each result as it completes (not just a final tally) and
    /// supports cancellation rather than running as one opaque blocking
    /// call -- with checkImageContents on, this is potentially hundreds
    /// of sequential hdiutil attach/detach cycles.
    public static func auditLibrary(
        under directory: URL,
        checkImageContents: Bool,
        config: AppConfig = ConfigStore.shared,
        onStart: @escaping (Int, Int, String) -> Void = { _, _, _ in },
        onResult: @escaping (Int, Int, MasterContentAuditResult) -> Void = { _, _, _ in },
        log: @escaping (String) -> Void = { _ in }
    ) async throws -> [MasterContentAuditResult] {
        let roots = findMasterRoots(under: directory, config: config)
        var results: [MasterContentAuditResult] = []
        for (index, root) in roots.enumerated() {
            try Task.checkCancellation()
            // Fired before the (potentially multi-second, with
            // checkImageContents on) work for this master starts --
            // onResult alone only ever reports what already finished,
            // which leaves the UI showing the *previous* master's name
            // for the whole time the current one is being mounted/read.
            onStart(index + 1, roots.count, root.lastPathComponent)
            let result = audit(masterRoot: root, checkImageContents: checkImageContents, config: config, log: log)
            results.append(result)
            onResult(index + 1, roots.count, result)
            await Task.yield()
        }
        return results
    }

    /// >15% short of the catalog-duration-derived expected size is
    /// flagged as possible missing content; a smaller gap is normal
    /// slack from container/ID3 overhead and BitrateFitting having
    /// reduced the actual encode bitrate to fit the drive. Only ever
    /// flags a shortfall, not an overage -- extra content isn't a
    /// missing-content problem.
    ///
    /// Reports the file count alongside the size gap, plus the encoding
    /// rate implied by actualBytes against the catalog's known duration
    /// (deliberately not a real AVFoundation duration probe -- this
    /// audit stays on cheap file-count/size stats, see the type's doc
    /// comment). A low implied rate against config.encoding.bitRate
    /// points at genuinely missing content; one close to it just means
    /// the shortfall is a low-bitrate encode, not a missing track.
    private static func appendSizeIssue(
        label: String, actualBytes: Int64, expectedBytes: Int64,
        fileCount: Int, expectedDurationSeconds: Int?, into issues: inout [String]
    ) {
        guard expectedBytes > 0 else { return }
        let delta = Double(actualBytes - expectedBytes) / Double(expectedBytes)
        guard delta < -0.15 else { return }
        let actualMib = Double(actualBytes) / 1024.0 / 1024.0
        let expectedMib = Double(expectedBytes) / 1024.0 / 1024.0
        var message = String(
            format: "%@ is %.1f MiB but catalog duration implies ~%.1f MiB \u{2014} possible missing content (%d file(s) found",
            label, actualMib, expectedMib, fileCount
        )
        if let expectedDurationSeconds, expectedDurationSeconds > 0 {
            let impliedKbps = Double(actualBytes) * 8.0 / Double(expectedDurationSeconds) / 1000.0
            message += String(format: ", ~%.0f kbps implied by size \u{00f7} catalog duration", impliedKbps)
        }
        message += ")"
        issues.append(message)
    }

    private static func findImageFile(inMasterRoot masterRoot: URL) -> URL? {
        let imageDir = masterRoot.appendingPathComponent("image")
        guard let entries = try? FileManager.default.contentsOfDirectory(at: imageDir, includingPropertiesForKeys: nil) else {
            return nil
        }
        return entries.first { $0.pathExtension.lowercased() == "img" }
    }

    // MARK: - Read-only .img mount

    enum ImageMountError: Error, CustomStringConvertible {
        case attachFailed(String)
        case noMountPoint

        var description: String {
            switch self {
            case .attachFailed(let detail): return "hdiutil attach failed: \(detail)"
            case .noMountPoint: return "hdiutil attach produced no mount point"
            }
        }
    }

    /// Attaches `imagePath` read-only, runs `body` with its mount
    /// point, then always detaches -- works for both this app's image
    /// layouts (bare-FAT superfloppy and MBR+FAT32) without needing to
    /// know which: Shell.mountPath scans every line hdiutil prints for
    /// one ending in a /Volumes/... path, which for an MBR image is the
    /// partition slice's line, and for a superfloppy image is the
    /// (only) device line itself.
    static func withMountedImage<T>(_ imagePath: URL, log: (String) -> Void = { _ in }, _ body: (URL) throws -> T) throws -> T {
        log("Mounting \(imagePath.path) read-only\u{2026}")
        let attachOut: String
        do {
            attachOut = try Shell.run("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", imagePath.path])
        } catch let error as ShellError {
            log("hdiutil attach failed: \(error.description)")
            throw ImageMountError.attachFailed(error.description)
        }
        guard let device = Shell.devicePath(fromAttachOutput: attachOut) else {
            log("hdiutil attach produced unparseable output: \(attachOut)")
            throw ImageMountError.attachFailed(attachOut)
        }
        defer {
            let detached = (try? Shell.run("/usr/bin/hdiutil", ["detach", device])) != nil
            log(detached ? "Detached \(device)." : "Warning: failed to detach \(device) -- it may still be mounted.")
        }
        guard let mountPointString = Shell.mountPath(fromAttachOutput: attachOut) else {
            log("hdiutil attach succeeded but reported no mount point: \(attachOut)")
            throw ImageMountError.noMountPoint
        }
        log("Mounted at \(mountPointString).")
        return try body(URL(fileURLWithPath: mountPointString))
    }
}
