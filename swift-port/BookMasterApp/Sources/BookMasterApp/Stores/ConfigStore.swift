import Foundation

/// Loads the bundled copy of config.json (encoding params, drive
/// capacity default, output structure, valid input formats). Read-only —
/// nothing in this app writes config.json, matching the Python side.
///
/// The bundled copy under Resources/ is a snapshot taken at Phase 1
/// scaffolding time; Phase 9 packaging needs to decide the long-term
/// story (bundled default vs. an editable file in Application Support)
/// rather than this silently drifting from src/config/config.json.
enum ConfigStore {
    static let shared: AppConfig = load()

    private static func load() -> AppConfig {
        guard let url = Bundle.module.url(forResource: "config", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(AppConfig.self, from: data) else {
            print("WARNING: could not load bundled config.json, using built-in fallback values")
            return .fallback
        }
        return config
    }
}
