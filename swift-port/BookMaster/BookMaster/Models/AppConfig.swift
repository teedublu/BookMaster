import Foundation

/// Mirrors src/config/config.json. Read-only from the app's perspective —
/// the Python side never writes this file at runtime, only settings.json.
public struct EncodingConfig: Codable, Equatable {
    public var bitRate: Int
    public var sampleRate: Int
    public var channels: Int
    public var targetLufs: Double

    enum CodingKeys: String, CodingKey {
        case bitRate = "bit_rate"
        case sampleRate = "sample_rate"
        case channels
        case targetLufs = "target_lufs"
    }
}

public struct OutputStructure: Codable, Equatable {
    public var tracksPath: String
    public var infoPath: String
    public var idFile: String
    public var countFile: String
    public var metadataFile: String
    public var checksumFile: String
    public var versionFile: String

    enum CodingKeys: String, CodingKey {
        case tracksPath = "tracks_path"
        case infoPath = "info_path"
        case idFile = "id_file"
        case countFile = "count_file"
        case metadataFile = "metadata_file"
        case checksumFile = "checksum_file"
        case versionFile = "version_file"
    }
}

public struct AppConfig: Codable, Equatable {
    public var encoding: EncodingConfig
    public var maxDriveSize: Int
    public var patternsToRemove: [String]
    public var outputStructure: OutputStructure
    public var validFormats: [String]

    enum CodingKeys: String, CodingKey {
        case encoding
        case maxDriveSize = "max_drive_size"
        case patternsToRemove = "patterns_to_remove"
        case outputStructure = "output_structure"
        case validFormats = "valid_formats"
    }

    /// A conservative built-in fallback, matching config.json's current
    /// values, used only if the real config file can't be found/parsed —
    /// mirrors Python's implicit behavior of just crashing loudly instead,
    /// but a GUI app crashing on launch because a config file is missing
    /// is worse UX than falling back with a visible warning (see
    /// ConfigStore.swift).
    public static let fallback = AppConfig(
        encoding: EncodingConfig(bitRate: 96000, sampleRate: 44100, channels: 1, targetLufs: -19),
        maxDriveSize: 980_000_000,
        patternsToRemove: ["._*", "*.DS_Store", ".fseventsd", ".Trashes", ".TemporaryItems",
                            ".Spotlight-V100", ".DocumentRevisions-V100", "System Volume Information", "*.tmp"],
        outputStructure: OutputStructure(
            tracksPath: "tracks", infoPath: "bookInfo", idFile: "bookInfo/id.txt",
            countFile: "bookInfo/count.txt", metadataFile: ".metadata_never_index",
            checksumFile: "bookInfo/checksum.txt", versionFile: "bookInfo/version.txt"
        ),
        validFormats: [".mp3", ".wav"]
    )
}
