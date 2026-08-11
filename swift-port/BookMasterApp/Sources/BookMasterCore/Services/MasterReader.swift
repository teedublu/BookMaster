import Foundation

public struct MasterContent: Equatable {
    public let isbn: String?
    public let fileCount: Int?
    public let checksumMatches: Bool?
}

/// Reads back a previously-written master structure from a mounted
/// drive (or any directory) — the "Check Master" counterpart to
/// MasterBuilder, ported from Master.load_master_from_drive()'s
/// id.txt/count.txt reads plus a live checksum re-verification against
/// the stored checksum.txt.
public enum MasterReader {
    public static func read(mountPath: URL, config: AppConfig = ConfigStore.shared) -> MasterContent {
        let isbn = (try? String(contentsOf: mountPath.appendingPathComponent(config.outputStructure.idFile), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let countText = (try? String(contentsOf: mountPath.appendingPathComponent(config.outputStructure.countFile), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let count = countText.flatMap { Int($0) }
        let storedChecksum = (try? String(contentsOf: mountPath.appendingPathComponent(config.outputStructure.checksumFile), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let actualChecksum = try? Checksum.compute(rootDirectory: mountPath)

        let checksumMatches: Bool?
        if let storedChecksum, let actualChecksum {
            checksumMatches = storedChecksum == actualChecksum
        } else {
            checksumMatches = nil
        }

        return MasterContent(isbn: isbn.flatMap { $0.isEmpty ? nil : $0 }, fileCount: count, checksumMatches: checksumMatches)
    }
}
