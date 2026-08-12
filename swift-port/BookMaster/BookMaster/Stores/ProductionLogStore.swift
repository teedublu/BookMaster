import Foundation
import Combine

/// Owns the ProductionLog/AppDatabase connection as a stable object
/// identity (@StateObject in ContentView), rather than the plain `let
/// productionLog = try? ProductionLog()` Phase 10 originally used --
/// that stored property re-ran sqlite3_open()+migrate() on every
/// SwiftUI body re-evaluation (ContentView is a struct; a bare `let`
/// property initializer isn't preserved across renders the way a
/// property wrapper's storage is). Reopening a local file that often
/// was merely wasteful; reopening a file on a mounted network share
/// (Settings.databasePath) on every keystroke/toggle would be a real
/// reliability problem, so this makes "open the database" an explicit,
/// infrequent action instead of an implicit per-render side effect.
@MainActor
public final class ProductionLogStore: ObservableObject {
    @Published public private(set) var log: ProductionLog?
    @Published public private(set) var lastError: String?
    @Published public private(set) var currentPath: URL?

    public init() {}

    /// Opens (or reopens) the database at `directory`/voxmaster.db. Safe
    /// to call repeatedly with the same resolved path -- skips the
    /// reopen so toggling unrelated settings doesn't churn the
    /// connection.
    public func open(inDirectory directory: URL) {
        let path = AppDatabase.resolvedPath(inDirectory: directory)
        guard path != currentPath else { return }
        do {
            log = ProductionLog(db: try AppDatabase(path: path))
            currentPath = path
            lastError = nil
        } catch {
            log = nil
            currentPath = nil
            lastError = "\(error)"
        }
    }
}
