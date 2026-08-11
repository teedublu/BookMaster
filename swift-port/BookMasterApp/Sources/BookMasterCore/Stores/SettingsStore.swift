import Foundation
import Combine

/// Mirrors src/settings.py's load_settings()/save_settings(): a per-user
/// JSON file holding the last-used UI state, loaded once at launch and
/// written back on changes.
///
/// Deliberately uses its own "BookMasterSwift" directory rather than
/// reusing the Python app's "VoxblockMaster" one (platformdirs ->
/// ~/Library/Application Support/VoxblockMaster/settings.json) — this is
/// still a Phase 1 prototype shell, and it must never read or overwrite
/// the real production app's settings file on a dev machine that has
/// both installed. Phase 9 (cutover) is where the two get reconciled,
/// deliberately, with the user's sign-off — not implicitly here.
@MainActor
public final class SettingsStore: ObservableObject {
    @Published public var settings: AppSettings

    private let fileURL: URL

    public init() {
        let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BookMasterSwift", isDirectory: true)
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        self.fileURL = supportDir.appendingPathComponent("settings.json")

        if let data = try? Data(contentsOf: fileURL),
           let loaded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            self.settings = loaded
        } else {
            self.settings = AppSettings()
            // Match load_settings()'s behavior of writing a fresh default
            // file the first time there isn't one to read.
            try? persist(AppSettings())
        }
    }

    public func save() {
        try? persist(settings)
    }

    private func persist(_ value: AppSettings) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try data.write(to: fileURL, options: .atomic)
    }

    public var settingsFilePath: String { fileURL.path }
}
