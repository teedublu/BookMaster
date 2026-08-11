import Foundation

/// Mirrors src/settings.py's DEFAULT_SETTINGS + the extra keys other
/// modules read/write on the same dict (past_master, usb_drive_tests,
/// sku/title/author, max_drive_size). Python treated settings as an
/// untyped dict with `.get(key, default)` everywhere; this struct makes
/// that shape explicit and gives every field the same default the
/// Python DEFAULT_SETTINGS did, decoded tolerantly so a settings.json
/// missing newer keys (or written by an older version of either app)
/// still loads instead of failing.
struct PastMaster: Codable, Equatable {
    var isbn: String = ""
    var sku: String = ""
    var author: String = ""
    var title: String = ""
    var inputFolder: String = ""
    var fileCountExpected: Int = 0

    enum CodingKeys: String, CodingKey {
        case isbn, sku, author, title
        case inputFolder = "input_folder"
        case fileCountExpected = "file_count_expected"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isbn = try c.decodeIfPresent(String.self, forKey: .isbn) ?? ""
        sku = try c.decodeIfPresent(String.self, forKey: .sku) ?? ""
        author = try c.decodeIfPresent(String.self, forKey: .author) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        inputFolder = try c.decodeIfPresent(String.self, forKey: .inputFolder) ?? ""
        fileCountExpected = try c.decodeIfPresent(Int.self, forKey: .fileCountExpected) ?? 0
    }
}

struct AppSettings: Codable, Equatable {
    var useWebcam: Bool = false
    var inputFolder: String = (NSHomeDirectory() as NSString).appendingPathComponent("Documents/VoxblockMaster")
    var outputFolder: String = (NSHomeDirectory() as NSString).appendingPathComponent("Documents/VoxblockMaster/output")
    var isbn: String = ""
    var manualData: Bool = false
    var lookupCsv: Bool = false
    var findIsbnFolder: Bool = false
    var skipEncoding: Bool = false
    var skipImageCreation: Bool = false
    /// Radio-button value: "480", "980", or "" (unset -> falls back to config.max_drive_size).
    /// Kept as a String, matching the Python UI's tk.StringVar, rather than
    /// an enum, so a value written by an older/newer build doesn't fail to
    /// decode — see drive_size.swift's resolveMaxDriveSize equivalent (Phase 2/3).
    var maxDriveSizeMB: String = ""
    var writeImageMode: Bool = false
    var usbDriveCheckOnMount: Bool = false
    /// Comma-separated, matching the Python UI's usb_drive_tests StringVar
    /// (e.g. "Silence,Loudness,Metadata"). Kept as a raw string rather than
    /// [String] to stay byte-compatible with settings.json files written
    /// by the Python app.
    var usbDriveTests: String = ""
    var sku: String = ""
    var title: String = ""
    var author: String = ""
    var pastMaster: PastMaster = PastMaster()

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
    }

    init() {}

    init(from decoder: Decoder) throws {
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
    }
}
