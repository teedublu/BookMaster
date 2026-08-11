import Foundation

/// Mirrors src/config/config.json. Read-only from the app's perspective —
/// the Python side never writes this file at runtime, only settings.json.
struct EncodingConfig: Codable, Equatable {
    var bitRate: Int
    var sampleRate: Int
    var channels: Int
    var targetLufs: Double

    enum CodingKeys: String, CodingKey {
        case bitRate = "bit_rate"
        case sampleRate = "sample_rate"
        case channels
        case targetLufs = "target_lufs"
    }
}

struct OutputStructure: Codable, Equatable {
    var tracksPath: String
    var infoPath: String
    var idFile: String
    var countFile: String
    var metadataFile: String
    var checksumFile: String
    var versionFile: String

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

struct AppConfig: Codable, Equatable {
    var encoding: EncodingConfig
    var maxDriveSize: Int
    var patternsToRemove: [String]
    var outputStructure: OutputStructure
    var validFormats: [String]

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
    static let fallback = AppConfig(
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
