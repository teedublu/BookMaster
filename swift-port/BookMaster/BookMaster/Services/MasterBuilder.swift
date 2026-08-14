import Foundation

/// Superfloppy (bare FAT, no partition table -- this app's original and
/// still-default layout) vs. MBR-partitioned FAT32 (ported from
/// voxmaster's rebuild-mbr, for target hardware that expects a real
/// partition table).
public enum ImageFormat: String, Equatable, CaseIterable {
    case superfloppy
    case mbr
}

public struct MasterInputs {
    public let isbn: String
    public let sku: String
    public let title: String
    public let author: String
    public let inputFolder: URL
    public let outputFolder: URL
    public let maxDriveSizeBytes: Int64
    public let imageFormat: ImageFormat
    public let stripInputTags: Bool
    /// When true, a previously-encoded track is left in place and skipped
    /// on the next run instead of being re-encoded, and nothing is
    /// deleted if the build is cancelled or fails partway through -- so a
    /// bad track elsewhere in the batch doesn't cost you the tracks that
    /// already encoded fine. When false (the default), every run starts
    /// from a clean slate: existing processed tracks are wiped up front,
    /// and anything this run created is removed again if it doesn't
    /// finish successfully.
    public let cacheFiles: Bool
    public let sampleRate: Int

    public init(isbn: String, sku: String, title: String, author: String, inputFolder: URL, outputFolder: URL, maxDriveSizeBytes: Int64, imageFormat: ImageFormat = .superfloppy, stripInputTags: Bool = false, cacheFiles: Bool = false, sampleRate: Int = 44100) {
        self.isbn = isbn
        self.sku = sku
        self.title = title
        self.author = author
        self.inputFolder = inputFolder
        self.outputFolder = outputFolder
        self.maxDriveSizeBytes = maxDriveSizeBytes
        self.imageFormat = imageFormat
        self.stripInputTags = stripInputTags
        self.cacheFiles = cacheFiles
        self.sampleRate = sampleRate
    }
}

/// Reported periodically during MasterBuilder.build() so the UI can
/// drive a determinate progress bar. `fractionComplete` weights each
/// track by its audio duration (a proxy for its encode time) rather than
/// by plain file count, so a handful of long chapters don't make the bar
/// crawl through most of its range on the first file; the image-assembly
/// phase is given a fixed share of the remaining work since there's no
/// per-byte progress signal available from the disk-image builders.
public struct MasterBuildProgress: Equatable {
    public enum Phase: Equatable {
        case encoding(track: Int, totalTracks: Int)
        case buildingImage
    }
    public let phase: Phase
    public let fractionComplete: Double
}

public struct MasterBuildResult {
    public let masterPath: URL
    public let imagePath: URL
    public let checksum: String?
    public let fileCount: Int
    public let bitRateUsed: Int
}

public enum MasterBuildError: Error, CustomStringConvertible {
    case validationFailed([String])
    case noAudioFilesFound(String)
    case trackCountMismatch(expected: Int, found: Int)

    public var description: String {
        switch self {
        case .validationFailed(let errors): return errors.joined(separator: "; ")
        case .noAudioFilesFound(let path): return "no valid audio files found in \(path)"
        case .trackCountMismatch(let expected, let found):
            return "encoded \(found) track(s) but expected \(expected) -- refusing to assemble a master with a mismatched track count (likely stale files left behind by a previous attempt)"
        }
    }
}

/// Ports the essential MasterDraft -> Master pipeline (validate, encode,
/// assemble the bookInfo structure, checksum, build the disk image),
/// tying together Phase 6's FFmpegEncoder and Phase 3's DiskImageBuilder
/// the same way create_master_structure() + calculate_encoding_for_drive_capacity()
/// did. Does NOT include the raw device write (Phase 4's
/// RawDeviceWriter is a separate, deliberately-gated step) or USB-check
/// test execution (Silence/Loudness/Metadata/Frames/Speed) — those stay
/// out of scope here.
public enum MasterBuilder {
    /// Ports MasterDraft.validate()'s core checks. Returns an empty
    /// array if valid.
    public static func validate(inputs: MasterInputs, validFormats: [String] = ConfigStore.shared.validFormats) -> [String] {
        var errors: [String] = []
        if inputs.isbn.isEmpty { errors.append("Missing or invalid ISBN") }
        if inputs.title.isEmpty { errors.append("Missing or invalid title") }
        if inputs.author.isEmpty { errors.append("Missing or invalid author") }
        if inputs.sku.isEmpty { errors.append("Missing or invalid SKU") }

        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: inputs.inputFolder.path, isDirectory: &isDir)
        if !exists || !isDir.boolValue {
            errors.append("Input folder does not exist: \(inputs.inputFolder.path)")
        } else {
            let audioFiles = findAudioFiles(in: inputs.inputFolder, validFormats: validFormats)
            if audioFiles.isEmpty {
                errors.append("No valid audio files found in input folder: \(inputs.inputFolder.path)")
            }
        }
        return errors
    }

    public static func build(
        inputs: MasterInputs,
        config: AppConfig = ConfigStore.shared,
        productionLog: ProductionLog? = nil,
        progress: @escaping (MasterBuildProgress) -> Void = { _ in },
        log: @escaping (String) -> Void = { _ in }
    ) async throws -> MasterBuildResult {
        let validationErrors = validate(inputs: inputs, validFormats: config.validFormats)
        guard validationErrors.isEmpty else {
            throw MasterBuildError.validationFailed(validationErrors)
        }

        let fm = FileManager.default
        let bookOutputPath = inputs.outputFolder.appendingPathComponent(inputs.sku)
        let masterPath = bookOutputPath.appendingPathComponent("master")
        let processedPath = bookOutputPath.appendingPathComponent("processed")
        let imageOutputPath = bookOutputPath.appendingPathComponent("image")

        let inputFiles = findAudioFiles(in: inputs.inputFolder, validFormats: config.validFormats)
        guard !inputFiles.isEmpty else {
            throw MasterBuildError.noAudioFilesFound(inputs.inputFolder.path)
        }
        log("Found \(inputFiles.count) input track(s)")

        // Duration + bitrate-fit pass -- also doubles as the per-track
        // weighting for the progress callback below, since encode time
        // roughly tracks source duration.
        var durations: [Double] = []
        for file in inputFiles {
            durations.append(try await AudioDuration.seconds(ofFileAt: file))
        }
        let estimatedTotalBytes = zip(durations, inputFiles).reduce(Int64(0)) { total, pair in
            total + Int64(config.encoding.bitRate) * Int64(pair.0) / 8
        }
        let bitRate = BitrateFitting.fitBitRate(
            currentSizeBytes: estimatedTotalBytes,
            currentBitRate: config.encoding.bitRate,
            maxDriveSizeBytes: inputs.maxDriveSizeBytes
        )
        log("Target bitrate: \(bitRate)bps (estimated \(estimatedTotalBytes) bytes for \(inputs.maxDriveSizeBytes)-byte drive)")

        // Image assembly has no per-byte progress signal, so it's given a
        // fixed slice (15%) of the total duration-weighted work instead of
        // being tracked step by step.
        let totalDurationWeight = durations.reduce(0, +)
        let imageBuildWeight = max(totalDurationWeight * 0.15, 0.001)
        let totalWork = totalDurationWeight + imageBuildWeight
        var cumulativeWork: Double = 0

        do {
            if inputs.cacheFiles {
                try fm.createDirectory(at: processedPath, withIntermediateDirectories: true)
                // Prune anything left over from a previous attempt that
                // doesn't correspond to one of *this* run's tracks -- e.g.
                // a straggler from a run against a larger input folder --
                // before deciding what to reuse. Left in place, a stale
                // file would silently ride along into the finished master
                // alongside this run's tracks (see trackCountMismatch below).
                let expectedNames = Set((1...inputFiles.count).map {
                    Self.outputFilename(index: $0, isbn: inputs.isbn, sku: inputs.sku)
                })
                let existingEntries = (try? fm.contentsOfDirectory(at: processedPath, includingPropertiesForKeys: nil)) ?? []
                for entry in existingEntries where !expectedNames.contains(entry.lastPathComponent) {
                    log("Removing stale cached file not part of this run: \(entry.lastPathComponent)")
                    try? fm.removeItem(at: entry)
                }
            } else {
                try? fm.removeItem(at: processedPath)
                try fm.createDirectory(at: processedPath, withIntermediateDirectories: true)
            }

            // Built up explicitly (one entry per input track) rather than
            // read back via contentsOfDirectory(processedPath) -- reading
            // the directory back would pick up any stray file that
            // happens to be sitting there, which is exactly how a prior
            // interrupted/differently-sized attempt's leftovers ended up
            // duplicated into a finished master.
            var processedFiles: [URL] = []
            for (index, file) in inputFiles.enumerated() {
                try Task.checkCancellation()
                let trackNumber = index + 1
                let outputName = Self.outputFilename(index: trackNumber, isbn: inputs.isbn, sku: inputs.sku)
                let outputPath = processedPath.appendingPathComponent(outputName)
                if inputs.cacheFiles, fm.fileExists(atPath: outputPath.path) {
                    log("Track \(trackNumber)/\(inputFiles.count) already cached, skipping: \(outputName)")
                } else {
                    log("Encoding track \(trackNumber)/\(inputFiles.count): \(file.lastPathComponent)")
                    let params = EncodeParameters(
                        sampleRate: inputs.sampleRate,
                        bitRate: bitRate,
                        targetLufs: config.encoding.targetLufs,
                        durationSeconds: durations[index],
                        stripMetadata: inputs.stripInputTags
                    )
                    _ = try FFmpegEncoder.encode(inputPath: file, outputPath: outputPath, parameters: params)
                }
                processedFiles.append(outputPath)
                cumulativeWork += durations[index]
                progress(MasterBuildProgress(
                    phase: .encoding(track: trackNumber, totalTracks: inputFiles.count),
                    fractionComplete: min(cumulativeWork / totalWork, 1.0)
                ))
            }

            try Task.checkCancellation()
            progress(MasterBuildProgress(phase: .buildingImage, fractionComplete: min(cumulativeWork / totalWork, 1.0)))

            // Belt-and-braces: every path in processedFiles was either just
            // encoded or confirmed to exist before being reused, so this
            // should always hold -- but a finished master silently
            // containing the wrong number of tracks is bad enough to
            // guard against explicitly rather than trust that invariant.
            let onDiskCount = processedFiles.filter { fm.fileExists(atPath: $0.path) }.count
            guard onDiskCount == inputFiles.count else {
                throw MasterBuildError.trackCountMismatch(expected: inputFiles.count, found: onDiskCount)
            }

            // Assemble the master structure, matching output_structure exactly.
            try? fm.removeItem(at: masterPath)
            try fm.createDirectory(at: masterPath, withIntermediateDirectories: true)
            let tracksDir = masterPath.appendingPathComponent(config.outputStructure.tracksPath)
            try fm.createDirectory(at: tracksDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: masterPath.appendingPathComponent(config.outputStructure.infoPath), withIntermediateDirectories: true)

            try Data(inputs.isbn.utf8).write(to: masterPath.appendingPathComponent(config.outputStructure.idFile))
            try Data(String(processedFiles.count).utf8).write(to: masterPath.appendingPathComponent(config.outputStructure.countFile))
            try Data(String(VERSION).utf8).write(to: masterPath.appendingPathComponent(config.outputStructure.versionFile))
            fm.createFile(atPath: masterPath.appendingPathComponent(config.outputStructure.metadataFile).path, contents: nil)

            for file in processedFiles {
                try fm.copyItem(at: file, to: tracksDir.appendingPathComponent(file.lastPathComponent))
            }

            // Checksum after tracks are in place, before checksum.txt is
            // written (writing it first would make the file hash itself).
            let checksum = try Checksum.compute(rootDirectory: masterPath)
            if let checksum {
                try Data(checksum.utf8).write(to: masterPath.appendingPathComponent(config.outputStructure.checksumFile))
            }
            log("Master structure assembled at \(masterPath.path), checksum=\(checksum ?? "nil")")

            let imageResult: DiskImageResult
            switch inputs.imageFormat {
            case .superfloppy:
                imageResult = try DiskImageBuilder.buildImage(
                    fromSourceFolder: masterPath,
                    volumeLabel: inputs.sku,
                    outputPath: imageOutputPath,
                    patternsToExclude: config.patternsToRemove,
                    log: log
                )
            case .mbr:
                imageResult = try MBRImageBuilder.buildImage(
                    fromSourceFolder: masterPath,
                    volumeLabel: inputs.sku,
                    outputPath: imageOutputPath,
                    patternsToExclude: config.patternsToRemove,
                    log: log
                )
            }

            if let productionLog {
                try? productionLog.upsertMasterCatalog(
                    sku: inputs.sku, imgPath: imageResult.imagePath.path, imageBytes: imageResult.sizeBytes,
                    imageMib1dp: Self.mib1dp(imageResult.sizeBytes),
                    usedMib1dp: Self.mib1dp(estimatedTotalBytes), imageFileCount: processedFiles.count,
                    imageTrackCount: processedFiles.count, imageIsbn: inputs.isbn
                )
            }

            progress(MasterBuildProgress(phase: .buildingImage, fractionComplete: 1.0))

            return MasterBuildResult(
                masterPath: masterPath,
                imagePath: imageResult.imagePath,
                checksum: checksum,
                fileCount: processedFiles.count,
                bitRateUsed: bitRate
            )
        } catch {
            // Cancelled or failed partway through: without cacheFiles, leave
            // nothing behind so the next attempt starts clean. With
            // cacheFiles, whatever tracks made it to disk stay put so a
            // re-run can pick up where this one left off.
            if !inputs.cacheFiles {
                try? fm.removeItem(at: processedPath)
                try? fm.removeItem(at: masterPath)
                try? fm.removeItem(at: imageOutputPath)
            }
            throw error
        }
    }

    // MARK: - Helpers

    static func mib1dp(_ bytes: Int64) -> Double {
        (Double(bytes) / 1024.0 / 1024.0 * 10).rounded() / 10
    }

    static func outputFilename(index: Int, isbn: String, sku: String) -> String {
        let indexStr = String(format: "%03d", index)
        let isbnSuffix = Slug.make(String(isbn.suffix(5)))
        let skuSuffix = Slug.make(String(sku.suffix(4))).uppercased()
        let base = "\(indexStr)_\(isbnSuffix)\(skuSuffix)"
        return String(base.prefix(13)) + ".mp3"
    }

    static func findAudioFiles(in folder: URL, validFormats: [String]) -> [URL] {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else {
            return []
        }
        let filtered = entries.filter { validFormats.contains($0.pathExtension.isEmpty ? "" : ".\($0.pathExtension.lowercased())") }
        return filtered.naturalSorted()
    }
}
