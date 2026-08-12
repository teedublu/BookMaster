import Foundation

public enum MasterResolveError: Error, CustomStringConvertible {
    case notFound(String)

    public var description: String {
        switch self {
        case .notFound(let input):
            return "no master image found for \"\(input)\" (checked the production catalog and the output folder)"
        }
    }
}

public struct ResolvedMaster: Equatable {
    public let sku: String
    public let imagePath: URL
    public let imageMib: Double
    public let usedMib: Double
}

/// Resolves what the user typed/scanned/picked (a SKU, an ISBN, or a
/// direct list selection) to an actual `.img` file to write -- ports
/// voxmaster's writer.py `_resolve_master`/`_resolve_root_img`, adapted
/// to this app's actual on-disk layout (MasterBuilder/DiskImageBuilder/
/// MBRImageBuilder all write to `<outputFolder>/<sku>/image/<sku>.img`,
/// regardless of image format -- unlike voxmaster's Python CLI, there's
/// no separate "MBR-<sku>.img" filename variant to disambiguate here).
///
/// Two sources, in order: the production catalog DB (accurate image/used
/// size, kept in sync by MasterBuilder.build's upsertMasterCatalog), then
/// a direct folder scan using this app's known output convention -- for
/// a master built before the DB was reachable, or on a different machine
/// that hasn't shared its catalog yet.
public enum MasterResolver {
    public static func resolve(input: String, outputFolder: URL, productionLog: ProductionLog?) -> Result<ResolvedMaster, MasterResolveError> {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .failure(.notFound(input)) }

        let sku = resolvedSKU(fromUserInput: trimmed)

        if let productionLog, let record = (try? productionLog.master(sku: sku)) ?? nil,
           let imgPathString = record.imgPath, FileManager.default.fileExists(atPath: imgPathString) {
            return .success(ResolvedMaster(
                sku: sku, imagePath: URL(fileURLWithPath: imgPathString),
                imageMib: record.imageMib1dp ?? 0, usedMib: record.usedMib1dp ?? 0
            ))
        }

        let fallbackPath = outputFolder.appendingPathComponent(sku).appendingPathComponent("image").appendingPathComponent("\(sku).img")
        guard FileManager.default.fileExists(atPath: fallbackPath.path) else {
            return .failure(.notFound(input))
        }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: fallbackPath.path)[.size] as? Int64) ?? nil
        let mib = ((Double(bytes ?? 0)) / 1024.0 / 1024.0 * 10).rounded() / 10
        // No cataloged "used" figure available from a bare file scan --
        // image size is the closest available stand-in until this master
        // gets properly cataloged (e.g. by rebuilding it with the DB
        // reachable).
        return .success(ResolvedMaster(sku: sku, imagePath: fallbackPath, imageMib: mib, usedMib: mib))
    }

    /// A 13-digit numeric input is treated as an ISBN and translated via
    /// the book catalog; anything else (a typed SKU, or a scanned SKU
    /// barcode) is used as-is.
    static func resolvedSKU(fromUserInput input: String) -> String {
        guard input.count == 13, input.allSatisfy(\.isNumber),
              let row = BooksCatalog.lookup(isbn: input), let sku = row["SKU"], !sku.isEmpty else {
            return input
        }
        return sku
    }
}
