import Foundation

/// Mirrors src/settings.py's DEFAULT_SETTINGS + the extra keys other
/// modules read/write on the same dict (past_master, usb_drive_tests,
/// sku/title/author, max_drive_size). Python treated settings as an
/// untyped dict with `.get(key, default)` everywhere; this struct makes
/// that shape explicit and gives every field the same default the
/// Python DEFAULT_SETTINGS did, decoded tolerantly so a settings.json
/// missing newer keys (or written by an older version of either app)
/// still loads instead of failing.
public struct PastMaster: Codable, Equatable {
    public var isbn: String = ""
    public var sku: String = ""
    public var author: String = ""
    public var title: String = ""
    public var inputFolder: String = ""
    public var fileCountExpected: Int = 0

    enum CodingKeys: String, CodingKey {
        case isbn, sku, author, title
        case inputFolder = "input_folder"
        case fileCountExpected = "file_count_expected"
    }

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isbn = try c.decodeIfPresent(String.self, forKey: .isbn) ?? ""
        sku = try c.decodeIfPresent(String.self, forKey: .sku) ?? ""
        author = try c.decodeIfPresent(String.self, forKey: .author) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        inputFolder = try c.decodeIfPresent(String.self, forKey: .inputFolder) ?? ""
        fileCountExpected = try c.decodeIfPresent(Int.self, forKey: .fileCountExpected) ?? 0
    }
}

public struct AppSettings: Codable, Equatable {
    public var useWebcam: Bool = false
    public var inputFolder: String = (NSHomeDirectory() as NSString).appendingPathComponent("Documents/VoxblockMaster")
    public var outputFolder: String = (NSHomeDirectory() as NSString).appendingPathComponent("Documents/VoxblockMaster/output")
    public var isbn: String = ""
    public var manualData: Bool = false
    public var lookupCsv: Bool = true
    public var findIsbnFolder: Bool = false
    public var skipEncoding: Bool = false
    public var skipImageCreation: Bool = false
    /// Radio-button value: "480", "980", or "" (unset -> falls back to config.max_drive_size).
    /// Kept as a String, matching the Python UI's tk.StringVar, rather than
    /// an enum, so a value written by an older/newer build doesn't fail to
    /// decode — see DriveSize.swift's resolveMaxDriveSize equivalent.
    public var maxDriveSizeMB: String = ""
    public var writeImageMode: Bool = false
    public var usbDriveCheckOnMount: Bool = false
    /// Comma-separated, matching the Python UI's usb_drive_tests StringVar
    /// (e.g. "Silence,Loudness,Metadata"). Kept as a raw string rather than
    /// [String] to stay byte-compatible with settings.json files written
    /// by the Python app.
    public var usbDriveTests: String = ""
    public var sku: String = ""
    public var title: String = ""
    public var author: String = ""
    public var pastMaster: PastMaster = PastMaster()
    /// "superfloppy" (bare FAT, this app's original default) or "mbr"
    /// (MBR-partitioned FAT32, ported from voxmaster's rebuild-mbr, for
    /// target hardware that expects a real partition table). Stored as a
    /// raw string, not the ImageFormat enum directly, for the same
    /// forward/backward-compatibility reason as maxDriveSizeMB.
    public var imageFormat: String = "mbr"
    /// Folder holding the production database (voxmaster.db). Empty means
    /// "use the local per-machine default" (AppDatabase.defaultPath()'s
    /// Application Support folder). Set to a mounted network share's path
    /// to make production history (writes/duplicator runs/block history)
    /// follow one person working from multiple machines/locations, rather
    /// than being siloed per-Mac.
    public var databasePath: String = ""

    enum CodingKeys: String, CodingKey {
        case useWebcam = "use_webcam"
        case inputFolder = "input_folder"
        case outputFolder = "output_folder"
        case isbn
        case manualData = "manual_data"
        case lookupCsv = "lookup_csv"
        case findIsbnFolder = "find_isbn_folder"
        case skipEncoding = "skip_encoding"
        case skipImageCreation = "skip_image_creation"
        case maxDriveSizeMB = "max_drive_size_mb"
        case writeImageMode = "write_image_mode"
        case usbDriveCheckOnMount = "usb_drive_check_on_mount"
        case usbDriveTests = "usb_drive_tests"
        case sku, title, author
        case pastMaster = "past_master"
        case imageFormat = "image_format"
        case databasePath = "database_path"
    }

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()
        useWebcam = try c.decodeIfPresent(Bool.self, forKey: .useWebcam) ?? defaults.useWebcam
        inputFolder = try c.decodeIfPresent(String.self, forKey: .inputFolder) ?? defaults.inputFolder
        outputFolder = try c.decodeIfPresent(String.self, forKey: .outputFolder) ?? defaults.outputFolder
        isbn = try c.decodeIfPresent(String.self, forKey: .isbn) ?? defaults.isbn
        manualData = try c.decodeIfPresent(Bool.self, forKey: .manualData) ?? defaults.manualData
        lookupCsv = try c.decodeIfPresent(Bool.self, forKey: .lookupCsv) ?? defaults.lookupCsv
        findIsbnFolder = try c.decodeIfPresent(Bool.self, forKey: .findIsbnFolder) ?? defaults.findIsbnFolder
        skipEncoding = try c.decodeIfPresent(Bool.self, forKey: .skipEncoding) ?? defaults.skipEncoding
        skipImageCreation = try c.decodeIfPresent(Bool.self, forKey: .skipImageCreation) ?? defaults.skipImageCreation
        // max_drive_size_mb has been written as either a string ("480") or
        // a bare number (480) depending on caller — tolerate both, mirroring
        // the Python side's str(...) coercion in main_window.py.
        if let s = try? c.decodeIfPresent(String.self, forKey: .maxDriveSizeMB) ?? nil {
            maxDriveSizeMB = s
        } else if let n = try? c.decodeIfPresent(Double.self, forKey: .maxDriveSizeMB) ?? nil {
            maxDriveSizeMB = n == n.rounded() ? String(Int(n)) : String(n)
        } else {
            maxDriveSizeMB = defaults.maxDriveSizeMB
        }
        writeImageMode = try c.decodeIfPresent(Bool.self, forKey: .writeImageMode) ?? defaults.writeImageMode
        usbDriveCheckOnMount = try c.decodeIfPresent(Bool.self, forKey: .usbDriveCheckOnMount) ?? defaults.usbDriveCheckOnMount
        usbDriveTests = try c.decodeIfPresent(String.self, forKey: .usbDriveTests) ?? defaults.usbDriveTests
        sku = try c.decodeIfPresent(String.self, forKey: .sku) ?? defaults.sku
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? defaults.title
        author = try c.decodeIfPresent(String.self, forKey: .author) ?? defaults.author
        pastMaster = try c.decodeIfPresent(PastMaster.self, forKey: .pastMaster) ?? defaults.pastMaster
        imageFormat = try c.decodeIfPresent(String.self, forKey: .imageFormat) ?? defaults.imageFormat
        databasePath = try c.decodeIfPresent(String.self, forKey: .databasePath) ?? defaults.databasePath
    }
}
