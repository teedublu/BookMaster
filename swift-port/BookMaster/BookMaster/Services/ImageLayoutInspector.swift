import Foundation

public enum ImageKind: String, Equatable {
    case mbrFat = "mbr-fat"
    case mbr = "mbr"
    case superfloppyFat = "superfloppy-fat"
    case unknown = "unknown"
}

public struct ImageLayout: Equatable {
    public let kind: ImageKind
    public let fatVariant: String?
    public let volumeLabel: String?
    public let partitionStartLBA: Int?
    public let partitionSectors: Int?
    public let imageBytes: Int64
}

private struct MBRPartitionEntry {
    let index: Int
    let partitionType: UInt8
    let startLBA: Int
    let sectorCount: Int
}

/// Ports rebuilder.py's raw byte-level MBR/FAT boot-sector inspection
/// (inspect_image_layout, _parse_mbr_entries, _fat_variant_and_label) --
/// read-only parsing used to detect what an existing .img file already
/// is (superfloppy FAT vs. MBR+FAT32 vs. neither) before deciding how to
/// build or validate an image. The exact byte offsets here were verified
/// against a real MBR image built with `diskutil partitionDisk` on this
/// machine, not just transcribed from the Python source blind.
public enum ImageLayoutInspector {
    private static let sectorSize = 512

    public static func inspect(_ imagePath: URL) throws -> ImageLayout {
        let handle = try FileHandle(forReadingFrom: imagePath)
        defer { try? handle.close() }
        let imageBytes = (try? FileManager.default.attributesOfItem(atPath: imagePath.path)[.size] as? Int64) ?? nil
        let totalBytes = imageBytes ?? Int64((try? handle.seekToEnd()) ?? 0)

        let sector0 = try readSector(handle, lba: 0)
        let entries = parseMBREntries(sector0)

        if let first = entries.first {
            let fatSector = try readSector(handle, lba: first.startLBA)
            let (fatVariant, label) = fatVariantAndLabel(fatSector)
            let kind: ImageKind = (entries.count == 1 && fatVariant != nil) ? .mbrFat : .mbr
            return ImageLayout(
                kind: kind, fatVariant: fatVariant, volumeLabel: label,
                partitionStartLBA: first.startLBA, partitionSectors: first.sectorCount, imageBytes: totalBytes
            )
        }

        let (fatVariant, label) = fatVariantAndLabel(sector0)
        if let fatVariant {
            return ImageLayout(kind: .superfloppyFat, fatVariant: fatVariant, volumeLabel: label, partitionStartLBA: nil, partitionSectors: nil, imageBytes: totalBytes)
        }
        return ImageLayout(kind: .unknown, fatVariant: nil, volumeLabel: nil, partitionStartLBA: nil, partitionSectors: nil, imageBytes: totalBytes)
    }

    // MARK: - Sector I/O

    private static func readSector(_ handle: FileHandle, lba: Int) throws -> Data {
        try handle.seek(toOffset: UInt64(lba * sectorSize))
        return (try handle.read(upToCount: sectorSize)) ?? Data()
    }

    // MARK: - MBR partition table (offset 446, 4 x 16-byte entries, 0x55AA at 510-511)

    private static func parseMBREntries(_ sector0: Data) -> [MBRPartitionEntry] {
        guard sector0.count >= sectorSize, sector0[510] == 0x55, sector0[511] == 0xAA else { return [] }

        var entries: [MBRPartitionEntry] = []
        for idx in 0..<4 {
            let off = 446 + (idx * 16)
            let partitionType = sector0[off + 4]
            let startLBA = readUInt32LE(sector0, at: off + 8)
            let sectorCount = readUInt32LE(sector0, at: off + 12)
            if partitionType == 0 || sectorCount == 0 { continue }
            entries.append(MBRPartitionEntry(index: idx + 1, partitionType: partitionType, startLBA: startLBA, sectorCount: sectorCount))
        }
        return entries
    }

    private static func readUInt32LE(_ data: Data, at offset: Int) -> Int {
        guard offset + 4 <= data.count else { return 0 }
        let b0 = Int(data[offset]), b1 = Int(data[offset + 1]), b2 = Int(data[offset + 2]), b3 = Int(data[offset + 3])
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    }

    private static func readUInt16LE(_ data: Data, at offset: Int) -> Int {
        guard offset + 2 <= data.count else { return 0 }
        return Int(data[offset]) | (Int(data[offset + 1]) << 8)
    }

    // MARK: - FAT boot sector detection

    private static func looksLikeFATBootSector(_ sector: Data) -> Bool {
        guard sector.count >= sectorSize, sector[510] == 0x55, sector[511] == 0xAA else { return false }
        guard sector[0] == 0xEB || sector[0] == 0xE9 else { return false }

        let bytesPerSector = readUInt16LE(sector, at: 11)
        let sectorsPerCluster = sector[13]
        let fatCount = sector[16]
        let mediaDescriptor = sector[21]

        guard [512, 1024, 2048, 4096].contains(bytesPerSector) else { return false }
        guard sectorsPerCluster != 0, fatCount != 0 else { return false }
        return mediaDescriptor >= 0xF0
    }

    private static func fatVariantAndLabel(_ sector: Data) -> (String?, String?) {
        guard looksLikeFATBootSector(sector) else { return (nil, nil) }

        let fsType16 = asciiString(sector, range: 54..<62).uppercased()
        let fsType32 = asciiString(sector, range: 82..<90).uppercased()
        let rootEntryCount = readUInt16LE(sector, at: 17)

        let fatVariant: String
        let labelRange: Range<Int>
        if fsType16.hasPrefix("FAT12") {
            fatVariant = "FAT12"; labelRange = 43..<54
        } else if fsType16.hasPrefix("FAT16") {
            fatVariant = "FAT16"; labelRange = 43..<54
        } else if fsType32.hasPrefix("FAT32") {
            fatVariant = "FAT32"; labelRange = 71..<82
        } else if rootEntryCount == 0 {
            fatVariant = "FAT32"; labelRange = 71..<82
        } else {
            fatVariant = "FAT16"; labelRange = 43..<54
        }

        let rawLabel = printableAsciiString(sector, range: labelRange).trimmingCharacters(in: .whitespaces)
        return (fatVariant, rawLabel.isEmpty ? nil : rawLabel)
    }

    private static func asciiString(_ data: Data, range: Range<Int>) -> String {
        guard range.upperBound <= data.count else { return "" }
        let bytes = data.subdata(in: range)
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }

    /// Mirrors Python's `"".join(ch for ch in ... if 32 <= ord(ch) <= 126)`.
    private static func printableAsciiString(_ data: Data, range: Range<Int>) -> String {
        guard range.upperBound <= data.count else { return "" }
        let bytes = data.subdata(in: range)
        let scalars = bytes.compactMap { byte -> Character? in
            guard byte >= 32, byte <= 126 else { return nil }
            return Character(UnicodeScalar(byte))
        }
        return String(scalars)
    }
}
