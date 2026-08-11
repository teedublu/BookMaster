import Foundation

public struct MasterInputs {
    public let isbn: String
    public let sku: String
    public let title: String
    public let author: String
    public let inputFolder: URL
    public let outputFolder: URL
    public let skipEncoding: Bool
    public let maxDriveSizeBytes: Int64

    public init(isbn: String, sku: String, title: String, author: String, inputFolder: URL, outputFolder: URL, skipEncoding: Bool, maxDriveSizeBytes: Int64) {
        self.isbn = isbn
        self.sku = sku
        self.title = title
        self.author = author
        self.inputFolder = inputFolder
        self.outputFolder = outputFolder
        self.skipEncoding = skipEncoding
        self.maxDriveSizeBytes = maxDriveSizeBytes
    }
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

    public var description: String {
        switch self {
        case .validationFailed(let errors): return errors.joined(separator: "; ")
        case .noAudioFilesFound(let path): return "no valid audio files found in \(path)"
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

        // Reuse already-processed tracks if skipEncoding was requested and
        // the count still matches, mirroring Master.process_tracks()'s
        // reuse check -- otherwise wipe and re-encode.
        var reused = false
        if inputs.skipEncoding, fm.fileExists(atPath: processedPath.path) {
            let existing = (try? fm.contentsOfDirectory(at: processedPath, includingPropertiesForKeys: nil)) ?? []
            if existing.count == inputFiles.count {
                reused = true
                log("skip_encoding requested and \(existing.count) processed files already present -- reusing.")
            }
        }

        // Duration + bitrate-fit pass (needed even when reusing, to know
        // what bitrate was targeted).
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

        if !reused {
            try? fm.removeItem(at: processedPath)
            try fm.createDirectory(at: processedPath, withIntermediateDirectories: true)

            for (index, file) in inputFiles.enumerated() {
                let trackNumber = index + 1
                let outputName = Self.outputFilename(index: trackNumber, isbn: inputs.isbn, sku: inputs.sku)
                let outputPath = processedPath.appendingPathComponent(outputName)
                log("Encoding track \(trackNumber)/\(inputFiles.count): \(file.lastPathComponent)")
                let params = EncodeParameters(
                    sampleRate: config.encoding.sampleRate,
                    bitRate: bitRate,
                    targetLufs: config.encoding.targetLufs,
                    durationSeconds: durations[index]
                )
                _ = try FFmpegEncoder.encode(inputPath: file, outputPath: outputPath, parameters: params)
            }
        }

        let processedFiles = (try? fm.contentsOfDirectory(at: processedPath, includingPropertiesForKeys: nil).naturalSorted()) ?? []

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

        let imageResult = try DiskImageBuilder.buildImage(
            fromSourceFolder: masterPath,
            volumeLabel: inputs.sku,
            outputPath: imageOutputPath,
            patternsToExclude: config.patternsToRemove,
            log: log
        )

        return MasterBuildResult(
            masterPath: masterPath,
            imagePath: imageResult.imagePath,
            checksum: checksum,
            fileCount: processedFiles.count,
            bitRateUsed: bitRate
        )
    }

    // MARK: - Helpers

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
