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
    /// When true, a track that already made it to the processed-tracks
    /// folder is left alone on the next Create Master run instead of
    /// being re-encoded, and nothing is deleted if the run is cancelled
    /// or fails partway through -- see MasterInputs.cacheFiles.
    public var cacheFiles: Bool = false
    /// Output sample rate in Hz -- 44100 or 48000, picked from the
    /// Sample Rate radio group in Create Master's Options.
    public var sampleRate: Int = 44100
    /// When true, encoding strips all metadata from the input file
    /// rather than letting ffmpeg carry it through to the output track
    /// (its default behavior) -- see FFmpegEncoder.encode's
    /// stripMetadata param and MasterBuilder's use of it.
    public var stripInputTags: Bool = false
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
    ///
    /// Defaults to every check on, not "" -- an empty string is honored
    /// literally as "nothing checked" (see ContentView.enabledDriveChecks),
    /// so it has to actually mean that, not "unconfigured." Defaulting it
    /// to "" made the Checks panel lie: every box rendered unchecked while
    /// Check Master silently ran the full deep scan anyway.
    public var usbDriveTests: String = "Metadata,Speed,Silence,Loudness,Frames"
    /// Allowed +/- deviation from config.json's target_lufs, as a
    /// percentage, before the Loudness check flags a track -- see
    /// AudioAnalysis.loudnessIsCloseToTarget. Exposed here rather than
    /// left as Track.py's hardcoded 5% so it's adjustable from the
    /// Verify tab (a target-format change, encoder revision, etc. can
    /// legitimately shift what "close enough" means).
    public var loudnessTolerancePercent: Double = 5.0
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
    /// Folder to watch for duplicator-machine log files (e.g. a NAS
    /// folder synced from Google Drive) -- scanned on launch and on
    /// demand for files not yet ingested, rather than requiring a manual
    /// "Import Duplicator Log..." pick every time. Empty means sync is
    /// off.
    public var duplicatorLogFolder: String = ""
    /// Root folder to recursively scan for built masters (<sku>/master,
    /// <sku>/image/<sku>.img) when auditing content across the whole
    /// library rather than one master at a time -- independent of
    /// outputFolder since the audit is often run against an archive/NAS
    /// copy of everything ever built, not just this machine's current
    /// output location. Empty means unset; defaults to outputFolder in
    /// the UI until the user points it elsewhere.
    public var mastersLibraryPath: String = ""

    enum CodingKeys: String, CodingKey {
        case useWebcam = "use_webcam"
        case inputFolder = "input_folder"
        case outputFolder = "output_folder"
        case isbn
        case manualData = "manual_data"
        case lookupCsv = "lookup_csv"
        case findIsbnFolder = "find_isbn_folder"
        case cacheFiles = "cache_files"
        case sampleRate = "sample_rate"
        case stripInputTags = "strip_input_tags"
        case maxDriveSizeMB = "max_drive_size_mb"
        case writeImageMode = "write_image_mode"
        case usbDriveCheckOnMount = "usb_drive_check_on_mount"
        case usbDriveTests = "usb_drive_tests"
        case loudnessTolerancePercent = "loudness_tolerance_percent"
        case sku, title, author
        case pastMaster = "past_master"
        case imageFormat = "image_format"
        case databasePath = "database_path"
        case duplicatorLogFolder = "duplicator_log_folder"
        case mastersLibraryPath = "masters_library_path"
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
        cacheFiles = try c.decodeIfPresent(Bool.self, forKey: .cacheFiles) ?? defaults.cacheFiles
        sampleRate = try c.decodeIfPresent(Int.self, forKey: .sampleRate) ?? defaults.sampleRate
        stripInputTags = try c.decodeIfPresent(Bool.self, forKey: .stripInputTags) ?? defaults.stripInputTags
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
        loudnessTolerancePercent = try c.decodeIfPresent(Double.self, forKey: .loudnessTolerancePercent) ?? defaults.loudnessTolerancePercent
        sku = try c.decodeIfPresent(String.self, forKey: .sku) ?? defaults.sku
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? defaults.title
        author = try c.decodeIfPresent(String.self, forKey: .author) ?? defaults.author
        pastMaster = try c.decodeIfPresent(PastMaster.self, forKey: .pastMaster) ?? defaults.pastMaster
        imageFormat = try c.decodeIfPresent(String.self, forKey: .imageFormat) ?? defaults.imageFormat
        databasePath = try c.decodeIfPresent(String.self, forKey: .databasePath) ?? defaults.databasePath
        duplicatorLogFolder = try c.decodeIfPresent(String.self, forKey: .duplicatorLogFolder) ?? defaults.duplicatorLogFolder
        mastersLibraryPath = try c.decodeIfPresent(String.self, forKey: .mastersLibraryPath) ?? defaults.mastersLibraryPath
    }
}
