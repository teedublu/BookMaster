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

        // v2 masters (built by the old Python tool) never had a correct
        // checksum.txt to begin with -- see MasterContentAuditor.audit
        // for why -- so only re-verify for v3+.
        let builtVersion = (try? String(contentsOf: mountPath.appendingPathComponent(config.outputStructure.versionFile), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let isV3OrLater = builtVersion.flatMap { Double($0) }.map { $0 >= 3.0 } ?? false

        let checksumMatches: Bool?
        if isV3OrLater {
            let storedChecksum = (try? String(contentsOf: mountPath.appendingPathComponent(config.outputStructure.checksumFile), encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let actualChecksum = try? Checksum.compute(rootDirectory: mountPath)
            if let storedChecksum, let actualChecksum {
                checksumMatches = storedChecksum == actualChecksum
            } else {
                checksumMatches = nil
            }
        } else {
            checksumMatches = nil
        }

        return MasterContent(isbn: isbn.flatMap { $0.isEmpty ? nil : $0 }, fileCount: count, checksumMatches: checksumMatches)
    }
}
