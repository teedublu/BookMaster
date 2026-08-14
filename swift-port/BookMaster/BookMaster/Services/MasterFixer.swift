import Foundation

/// The fixes Verify Master can apply to a mounted drive -- deliberately
/// separate from DriveVerifier.verify(), which only ever reports what
/// it finds. Each fix here is an explicit, opt-in action the operator
/// chooses (see ContentView's "Fixes to make..." panel), not something
/// that happens silently as a side effect of checking.
public enum MasterFixer {
    /// Actually deletes the macOS artifacts verify() only reports on
    /// (dryRun there) -- e.g. .DS_Store, "._*" AppleDouble files.
    @discardableResult
    public static func removeArtifacts(at mountPoint: URL) -> (found: Int, removed: Int, samples: [String]) {
        DriveVerifier.removeUnexpectedEntries(at: mountPoint, dryRun: false)
    }

    /// Strips the ID3 tag entirely from every track DriveVerifier
    /// flagged (see scanForID3TagIssues) -- a full reset for that file,
    /// not a surgical edit of just the offending frame, since a file
    /// already flagged as carrying unexpected/mismatched tag content
    /// isn't a file worth trying to salvage frame-by-frame. Re-scans
    /// rather than reusing a prior VerificationResult's (possibly
    /// sample-capped) issue list, so this always acts on everything
    /// currently wrong, not just what the last check happened to show.
    @discardableResult
    public static func cleanID3Tags(tracksPath: URL, isbn: String?) -> (flagged: Int, cleaned: Int, samples: [String]) {
        let issues = DriveVerifier.scanForID3TagIssues(tracksPath: tracksPath, isbn: isbn, sampleLimit: .max)
        let flaggedFiles = Set(issues.map(\.fileName)).sorted()

        var cleaned = 0
        var samples: [String] = []
        for name in flaggedFiles {
            let url = tracksPath.appendingPathComponent(name)
            if ID3Tag.stripTags(at: url) {
                cleaned += 1
                if samples.count < 10 { samples.append(name) }
            }
        }
        return (flaggedFiles.count, cleaned, samples)
    }
}
