import Foundation

public struct MBRConversionIssue: Equatable {
    public let sku: String
    public let message: String
}

public struct MBRConvertedImage: Equatable {
    public let sku: String
    public let imagePath: URL
}

public struct MBRConversionSummary: Equatable {
    public let converted: [MBRConvertedImage]
    public let skipped: [MBRConversionIssue]
    public let failures: [MBRConversionIssue]

    public var isEmpty: Bool { converted.isEmpty && skipped.isEmpty && failures.isEmpty }
}

/// Ports voxmaster's `rebuild-mbr`: rebuilds a bare-FAT superfloppy master image as an MBR-partitioned
/// FAT32 one, next to the original as `MBR-<name>.img`.
///
/// The new image is built fresh from the source's mounted contents (MBRImageBuilder), not converted
/// byte for byte. The source is only ever mounted read-only, and an existing destination is never
/// overwritten.
public enum MBRImageConverter {
    /// `MBR-<name>.img` in the source's own folder.
    static func outputURL(forSource source: URL) -> URL {
        let name = source.deletingPathExtension().lastPathComponent
        return source.deletingLastPathComponent().appendingPathComponent(MBRImageBuilder.imageFilename(volumeLabel: name))
    }

    public static func convert(
        sourceImage: URL,
        minSizeMib: Int = 128,
        patternsToExclude: [String] = ConfigStore.shared.patternsToRemove,
        log: (String) -> Void = { _ in }
    ) throws -> DiskImageResult {
        let layout = try ImageLayoutInspector.inspect(sourceImage)
        guard layout.kind == .superfloppyFat else {
            throw MBRImageError.notSuperfloppy(layout.kind.rawValue)
        }
        let destination = outputURL(forSource: sourceImage)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw MBRImageError.destinationExists(destination.path)
        }

        log("Converting \(sourceImage.lastPathComponent) (\(layout.fatVariant ?? "FAT"), label \(layout.volumeLabel ?? "-")) to \(destination.lastPathComponent)")
        return try MasterContentAuditor.withMountedImage(sourceImage, log: log) { sourceRoot in
            try MBRImageBuilder.buildImage(
                fromSourceFolder: sourceRoot,
                volumeLabel: sourceImage.deletingPathExtension().lastPathComponent,
                outputPath: destination.deletingLastPathComponent(),
                fatLabel: layout.volumeLabel,
                minSizeMib: minSizeMib,
                patternsToExclude: patternsToExclude,
                log: log
            )
        }
    }

    /// Converts every superfloppy image in the `<sku>/image/` folders under `root`. Images already in
    /// MBR layout, or whose `MBR-` twin exists, are skipped. With a `productionLog`, each new image is
    /// recorded in the `masters` table straight away, since it is now the newest image for its SKU.
    public static func convertAll(
        under root: URL,
        productionLog: ProductionLog? = nil,
        minSizeMib: Int = 128,
        config: AppConfig = ConfigStore.shared,
        onStart: @escaping (Int, Int, String) -> Void = { _, _, _ in },
        log: @escaping (String) -> Void = { _ in }
    ) async throws -> MBRConversionSummary {
        var skipped: [MBRConversionIssue] = []
        var failures: [MBRConversionIssue] = []
        var pending: [(sku: String, source: URL)] = []

        for (sku, images) in MasterCatalogSync.findMasterImageFolders(under: root.canonicalized()) {
            for image in images where !image.lastPathComponent.hasPrefix(MBRImageBuilder.filenamePrefix) {
                do {
                    switch try ImageLayoutInspector.inspect(image).kind {
                    case .superfloppyFat:
                        let output = outputURL(forSource: image)
                        if FileManager.default.fileExists(atPath: output.path) {
                            skipped.append(MBRConversionIssue(sku: sku, message: "\(output.lastPathComponent) already exists"))
                        } else {
                            pending.append((sku, image))
                        }
                    case .mbrFat, .mbr:
                        skipped.append(MBRConversionIssue(sku: sku, message: "\(image.lastPathComponent) is already MBR"))
                    case .unknown:
                        failures.append(MBRConversionIssue(sku: sku, message: "\(image.lastPathComponent) is not a FAT disk image"))
                    }
                } catch {
                    failures.append(MBRConversionIssue(sku: sku, message: "\(image.lastPathComponent): \(error)"))
                }
            }
        }
        for issue in failures { log("\(issue.sku): skipped \u{2014} \(issue.message)") }
        log("Found \(pending.count) superfloppy image(s) to convert under \(root.path), \(skipped.count) skipped.")

        var converted: [MBRConvertedImage] = []
        for (index, item) in pending.enumerated() {
            try Task.checkCancellation()
            onStart(index + 1, pending.count, item.sku)
            do {
                let result = try convert(
                    sourceImage: item.source, minSizeMib: minSizeMib, patternsToExclude: config.patternsToRemove, log: log
                )
                converted.append(MBRConvertedImage(sku: item.sku, imagePath: result.imagePath))
                log("\(item.sku): converted to \(result.imagePath.lastPathComponent) (\(MasterBuilder.mib1dp(result.sizeBytes)) MiB)")
                if let productionLog {
                    do {
                        guard let identity = ImageFileIdentity(path: result.imagePath) else {
                            throw MasterCatalogError.unreadableImageFile(result.imagePath.path)
                        }
                        try MasterCatalogSync.record(
                            MasterImage(sku: item.sku, path: result.imagePath), identity: identity, in: productionLog, config: config
                        )
                    } catch {
                        log("\(item.sku): converted, but recording it in the catalog failed \u{2014} \(error). Run Update Known Masters to retry.")
                    }
                }
            } catch {
                failures.append(MBRConversionIssue(sku: item.sku, message: "\(error)"))
                log("\(item.sku): conversion failed \u{2014} \(error)")
            }
            await Task.yield()
        }

        return MBRConversionSummary(converted: converted, skipped: skipped, failures: failures)
    }
}
