import Foundation
#if canImport(Darwin)
import Darwin
#endif

public struct MasterCatalogFailure: Equatable {
    public let sku: String
    public let error: String
}

public struct MasterCatalogSummary: Equatable {
    public let updatedSkus: [String]
    public let skippedUnchangedCount: Int
    public let failures: [MasterCatalogFailure]

    public var isEmpty: Bool { updatedSkus.isEmpty && skippedUnchangedCount == 0 && failures.isEmpty }
}

struct MasterImage: Equatable {
    let sku: String
    let path: URL
}

struct MasterImageContents: Equatable {
    let usedKiB: UInt64
    let fileCount: Int
    let trackCount: Int
    let isbn: String?
    let unexpectedEntryCount: Int
    let unexpectedEntrySamples: [String]
}

struct ImageFileIdentity: Equatable {
    let bytes: Int64
    let createdAt: String?
    let modifiedAt: String?

    init?(path: URL) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path.path),
              let bytes = attrs[.size] as? Int64 else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        self.bytes = bytes
        createdAt = (attrs[.creationDate] as? Date).map(formatter.string(from:))
        modifiedAt = (attrs[.modificationDate] as? Date).map(formatter.string(from:))
    }
}

enum MasterCatalogError: Error, CustomStringConvertible {
    case unreadableImageFile(String)
    case statfsFailed(path: String, reason: String)

    var description: String {
        switch self {
        case .unreadableImageFile(let path): return "could not read file attributes of \(path)"
        case .statfsFailed(let path, let reason): return "could not read filesystem usage of \(path): \(reason)"
        }
    }
}

/// Ports voxmaster's catalog.py: records built master images found on a drive/folder into the `masters` table.
public enum MasterCatalogSync {
    public static func sync(
        root: URL,
        productionLog: ProductionLog,
        recheckUnchanged: Bool = false,
        config: AppConfig = ConfigStore.shared,
        onStart: @escaping (Int, Int, String) -> Void = { _, _, _ in },
        log: @escaping (String) -> Void = { _ in }
    ) async throws -> MasterCatalogSummary {
        let discovery = findMasterImages(under: root.canonicalized())
        try Task.checkCancellation()

        let known = Dictionary(try productionLog.allMasters().map { ($0.sku, $0) }, uniquingKeysWith: { first, _ in first })
        var failures = discovery.failures
        var pending: [(image: MasterImage, identity: ImageFileIdentity)] = []
        var skipped = 0
        for image in discovery.images {
            guard let identity = ImageFileIdentity(path: image.path) else {
                failures.append(MasterCatalogFailure(sku: image.sku, error: MasterCatalogError.unreadableImageFile(image.path.path).description))
                continue
            }
            if !recheckUnchanged, let record = known[image.sku], isUnchanged(record, image: image, identity: identity) {
                skipped += 1
            } else {
                pending.append((image, identity))
            }
        }
        for failure in discovery.failures {
            log("\(failure.sku): skipped \u{2014} \(failure.error)")
        }
        log("Found \(discovery.images.count) master image(s) under \(root.path): \(pending.count) to read, \(skipped) unchanged.")

        var updated: [String] = []
        for (index, entry) in pending.enumerated() {
            try Task.checkCancellation()
            let sku = entry.image.sku
            onStart(index + 1, pending.count, sku)
            do {
                let contents = try record(entry.image, identity: entry.identity, in: productionLog, config: config)
                let usedMib = mib1dp(fromKiB: contents.usedKiB)
                let imageMib = MasterBuilder.mib1dp(entry.identity.bytes)
                updated.append(sku)
                var line = "\(sku): used \(usedMib) MiB, image \(imageMib) MiB, \(contents.fileCount) file(s), \(contents.trackCount) track(s), ISBN \(contents.isbn ?? "-")"
                if contents.unexpectedEntryCount > 0 {
                    line += " \u{2014} \u{26A0}\u{FE0F} \(contents.unexpectedEntryCount) unexpected entr\(contents.unexpectedEntryCount == 1 ? "y" : "ies"): \(contents.unexpectedEntrySamples.joined(separator: ", "))"
                }
                log(line)
            } catch {
                failures.append(MasterCatalogFailure(sku: sku, error: "\(error)"))
                log("\(sku): skipped \u{2014} \(error)")
            }
            await Task.yield()
        }

        return MasterCatalogSummary(updatedSkus: updated, skippedUnchangedCount: skipped, failures: failures)
    }

    /// Reads `image` and writes (or refreshes) its row in the `masters` table.
    @discardableResult
    static func record(
        _ image: MasterImage, identity: ImageFileIdentity, in productionLog: ProductionLog, config: AppConfig = ConfigStore.shared
    ) throws -> MasterImageContents {
        let contents = try inspectImage(at: image.path, config: config)
        try productionLog.upsertScannedMaster(
            sku: image.sku, imgPath: image.path.path, imageBytes: identity.bytes,
            imageMib1dp: MasterBuilder.mib1dp(identity.bytes), usedMib1dp: mib1dp(fromKiB: contents.usedKiB),
            imageFileCount: contents.fileCount, imageTrackCount: contents.trackCount, imageIsbn: contents.isbn,
            createdAt: identity.createdAt, modifiedAt: identity.modifiedAt
        )
        return contents
    }

    /// Finds `<sku>/image/` folders holding `.img` files at any depth, not descending into a matched SKU folder.
    static func findMasterImageFolders(under directory: URL) -> [(sku: String, images: [URL])] {
        let fm = FileManager.default
        var folders: [(sku: String, images: [URL])] = []

        func walk(_ folder: URL) {
            guard !Task.isCancelled else { return }
            let imageFiles = imgFiles(in: folder.appendingPathComponent("image"))
            if !imageFiles.isEmpty {
                folders.append((folder.lastPathComponent, imageFiles))
                return
            }

            let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
            let children = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let values = try? child.resourceValues(forKeys: Set(keys))
                guard values?.isDirectory == true, values?.isPackage != true else { continue }
                walk(child)
            }
        }

        walk(directory)
        return folders
    }

    /// Picks each folder's master from `findMasterImageFolders`: `<sku>.img` or `MBR-<sku>.img` (the newest).
    static func findMasterImages(under directory: URL) -> (images: [MasterImage], failures: [MasterCatalogFailure]) {
        var images: [MasterImage] = []
        var failures: [MasterCatalogFailure] = []

        for (sku, imageFiles) in findMasterImageFolders(under: directory) {
            // <sku>.img and MBR-<sku>.img can sit side by side (voxmaster's rebuild-mbr, or a rebuild
            // in the other format); the newest is the current master, <sku>.img winning a tie.
            let names = Set(MasterResolver.imageFilenames(forSKU: sku))
            if let named = MasterResolver.newestImage(among: imageFiles.filter { names.contains($0.lastPathComponent) }) {
                images.append(MasterImage(sku: sku, path: named))
            } else if imageFiles.count == 1 {
                images.append(MasterImage(sku: sku, path: imageFiles[0]))
            } else {
                failures.append(MasterCatalogFailure(
                    sku: sku, error: "image/ holds \(imageFiles.count) .img files and none is named \(sku).img or MBR-\(sku).img"
                ))
            }
        }
        return (images, failures)
    }

    private static func imgFiles(in imageDirectory: URL) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: imageDirectory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        )) ?? []
        return entries
            .filter { url in
                url.pathExtension.lowercased() == "img"
                    && (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // Only a scan stores the file's own timestamps, so a row written right after a build (estimated used size) never matches.
    static func isUnchanged(_ record: MasterRecord, image: MasterImage, identity: ImageFileIdentity) -> Bool {
        record.imgPath == image.path.path
            && record.imageBytes == identity.bytes
            && record.createdAt == identity.createdAt
            && record.modifiedAt == identity.modifiedAt
    }

    static func inspectImage(at imagePath: URL, config: AppConfig) throws -> MasterImageContents {
        try MasterContentAuditor.withMountedImage(imagePath) { mountPoint in
            let fm = FileManager.default
            let fileCount = RawDirectoryLister.allEntriesRecursively(at: mountPoint).filter { relativePath in
                guard !DriveVerifier.isUnexpectedEntry(relativePath) else { return false }
                var isDirectory: ObjCBool = false
                return fm.fileExists(atPath: mountPoint.appendingPathComponent(relativePath).path, isDirectory: &isDirectory)
                    && !isDirectory.boolValue
            }.count
            let unexpected = DriveVerifier.removeUnexpectedEntries(at: mountPoint, dryRun: true)
            let tracks = AudioProfiler.measureTrackAudioBytes(tracksPath: mountPoint.appendingPathComponent(config.outputStructure.tracksPath))
            let isbn = (try? String(contentsOf: mountPoint.appendingPathComponent(config.outputStructure.idFile), encoding: .utf8))
                .flatMap(DriveVerifier.parseISBN(fromIdFileText:))
            return MasterImageContents(
                usedKiB: try usedKiB(ofVolumeAt: mountPoint), fileCount: fileCount, trackCount: tracks.fileCount, isbn: isbn,
                unexpectedEntryCount: unexpected.found, unexpectedEntrySamples: unexpected.samples
            )
        }
    }

    /// The `df -k` "Used" figure voxmaster's catalog recorded, which duplicator log data sizes are matched against.
    static func usedKiB(ofVolumeAt mountPoint: URL) throws -> UInt64 {
        var fs = statfs()
        guard statfs(mountPoint.path, &fs) == 0 else {
            throw MasterCatalogError.statfsFailed(path: mountPoint.path, reason: String(cString: strerror(errno)))
        }
        return (fs.f_blocks - fs.f_bfree) * UInt64(fs.f_bsize) / 1024
    }

    static func mib1dp(fromKiB kib: UInt64) -> Double {
        (Double(kib) / 1024.0 * 10).rounded() / 10
    }
}
