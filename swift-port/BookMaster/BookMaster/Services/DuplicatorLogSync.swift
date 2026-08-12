import Foundation

public struct DuplicatorSyncFailure: Equatable {
    public let fileName: String
    public let error: String
}

public struct DuplicatorSyncSummary: Equatable {
    public let syncedFileNames: [String]
    public let skippedAlreadySyncedCount: Int
    public let failures: [DuplicatorSyncFailure]
    public let rowsInserted: Int

    public var isEmpty: Bool { syncedFileNames.isEmpty && failures.isEmpty }
}

/// Scans a folder (e.g. a NAS folder synced from Google Drive) for
/// duplicator-machine log files not yet ingested, and ingests each new
/// one via the same ProductionLog.insertDuplicatorRuns path "Import
/// Duplicator Log..." already uses -- so syncing a folder is just
/// "do the manual import for every file I haven't already imported",
/// not a separate ingestion path to keep in sync with that one.
///
/// Dedup is by filename, not full path: a sync layer relocating a file
/// (different NAS mount point, Drive's local cache path differing per
/// machine) shouldn't cause it to be re-ingested and double-counted.
/// Matches the real files this was built against (`duplicator-logs/`
/// examples) -- each is a discrete dated export from the duplicator
/// machine (a "Print Date"/date-range header per file), not a single
/// continuously-appended log, so "already saw this filename" is a
/// sound sync unit.
public enum DuplicatorLogSync {
    static let recognizedExtensions: Set<String> = ["txt", "log"]

    /// `async` even though the body is fully synchronous blocking I/O
    /// (file reads, SQL) -- matching MasterBuilder.build/DriveVerifier.verify's
    /// pattern elsewhere in this app, so calling this from a bare `Task {
    /// }` in ContentView runs it off the main thread instead of freezing
    /// the UI while a folder full of multi-megabyte log files gets parsed.
    @discardableResult
    public static func sync(folder: URL, productionLog: ProductionLog, log: @escaping (String) -> Void = { _ in }) async -> DuplicatorSyncSummary {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) else {
            log("Could not read log folder: \(folder.path)")
            return DuplicatorSyncSummary(syncedFileNames: [], skippedAlreadySyncedCount: 0, failures: [], rowsInserted: 0)
        }

        let candidateFiles = entries
            .filter { url in
                let isFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
                return isFile && recognizedExtensions.contains(url.pathExtension.lowercased())
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        let alreadySynced = (try? productionLog.syncedDuplicatorLogFileNames()) ?? []

        var syncedFileNames: [String] = []
        var failures: [DuplicatorSyncFailure] = []
        var skipped = 0
        var totalInserted = 0

        for file in candidateFiles {
            let name = file.lastPathComponent
            if alreadySynced.contains(name) {
                skipped += 1
                continue
            }
            do {
                let rows = try DuplicatorLogParser.parseLog(at: file)
                guard !rows.isEmpty else {
                    log("\(name): no valid log rows found, skipping")
                    continue
                }
                let inserted = try productionLog.insertDuplicatorRuns(sourceFile: file.path, rows: rows)
                totalInserted += inserted
                syncedFileNames.append(name)
                log("Synced \(name): \(inserted) row(s)")
            } catch {
                failures.append(DuplicatorSyncFailure(fileName: name, error: "\(error)"))
                log("Failed to sync \(name): \(error)")
            }
        }

        return DuplicatorSyncSummary(
            syncedFileNames: syncedFileNames, skippedAlreadySyncedCount: skipped,
            failures: failures, rowsInserted: totalInserted
        )
    }
}
