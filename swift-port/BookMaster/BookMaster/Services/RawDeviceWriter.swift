import Foundation

public enum RawWriteError: Error, CustomStringConvertible {
    case targetNotAllowedByPattern(String)
    case targetNotCurrentlyACandidate(String)
    case sourceMissing(String)
    case openFailed(path: String, errno: Int32)
    case shortWrite(expected: Int, actual: Int, errno: Int32)
    case fsyncFailed(errno: Int32)
    case elevatedWriteFailed(String)

    public var description: String {
        switch self {
        case .targetNotAllowedByPattern(let path):
            return "\(path) does not match the allowed raw-whole-disk pattern (^/dev/rdisk[0-9]+$)"
        case .targetNotCurrentlyACandidate(let bsdName):
            return "\(bsdName) is not currently a live USB removable-whole-disk candidate"
        case .sourceMissing(let path):
            return "source image not found: \(path)"
        case .openFailed(let path, let err):
            return "could not open \(path) for writing: \(String(cString: strerror(err)))"
        case .shortWrite(let expected, let actual, let err):
            return "short write: expected \(expected) bytes, wrote \(actual) (errno \(err): \(String(cString: strerror(err))))"
        case .fsyncFailed(let err):
            return "fsync failed: \(String(cString: strerror(err)))"
        case .elevatedWriteFailed(let detail):
            return "administrator-privileged write failed: \(detail)"
        }
    }
}

/// Proof that a specific device was independently re-verified as a safe
/// write target immediately before use — this is Phase 0/2's central
/// safety finding turned into a type: `RawDeviceWriter.write` only
/// accepts one of these, not a bare path string, so it is structurally
/// impossible to write to a device that hasn't just passed both gates.
///
/// Two independent checks, both required (from RawWriteSpike's README):
/// 1. Path-pattern allowlist (`^/dev/rdisk[0-9]+$`, whole raw disk only)
///    — necessary but proven NOT sufficient on its own: `/dev/rdisk0`
///    (a real machine's boot disk) matches this pattern.
/// 2. A live re-check against the *current* candidate list — not a
///    cached `USBDriveInfo` the UI might be holding from moments ago —
///    confirming DiskArbitration still reports this exact device as
///    removable + whole + USB right now.
public struct RawWriteAuthorization {
    public let bsdName: String
    public let rawDevicePath: String

    // Not public: real app code can only obtain an instance via
    // `authorize()`. Internal (not private) so BookMasterCoreTests can
    // construct fixtures directly via `@testable import` to test
    // RawDeviceWriter.write()'s I/O mechanics in isolation from the
    // gating logic, which is tested separately and exhaustively below.
    init(bsdName: String, rawDevicePath: String) {
        self.bsdName = bsdName
        self.rawDevicePath = rawDevicePath
    }

    /// `currentCandidates` should be the monitor's live list fetched at
    /// the moment of the write attempt (e.g. `usbMonitor.drives`), not a
    /// value captured earlier when the user made their selection — the
    /// whole point is to catch a device that changed state (or was
    /// swapped) in between.
    public static func authorize(drive: USBDriveInfo, currentCandidates: [USBDriveInfo]) -> Result<RawWriteAuthorization, RawWriteError> {
        guard isAllowedRawTargetPattern(drive.rawDevicePath) else {
            return .failure(.targetNotAllowedByPattern(drive.rawDevicePath))
        }
        guard let current = currentCandidates.first(where: { $0.bsdName == drive.bsdName }),
              current.isCandidate,
              current.rawDevicePath == drive.rawDevicePath else {
            return .failure(.targetNotCurrentlyACandidate(drive.bsdName))
        }
        return .success(RawWriteAuthorization(bsdName: current.bsdName, rawDevicePath: current.rawDevicePath))
    }

    /// Whole raw disk only (`/dev/rdiskN`) — never a slice (`/dev/rdiskNsM`)
    /// and never the buffered ("/dev/diskN", no "r") node.
    static func isAllowedRawTargetPattern(_ path: String) -> Bool {
        path.range(of: #"^/dev/rdisk[0-9]+$"#, options: .regularExpression) != nil
    }
}

/// Chunked POSIX write + fsync, replacing the Python version's
/// `dd of=<raw_whole> bs=4m conv=fsync` subprocess call with native I/O
/// (proven equivalent in Phase 0's RawWriteSpike via checksum
/// round-trip). In practice, macOS only grants the logged-in console
/// user direct read/write on a removable disk's device node once
/// DiskArbitration has claimed it (typically by mounting a recognized
/// filesystem on it at least once) — a blank/never-mounted target stays
/// root:operator with no write access for anyone else, so `writeDirect`
/// surfaces EACCES for exactly the targets this app is most likely to be
/// pointed at. `write()` tries that fast unprivileged path first and only
/// falls back to `writeElevated` when it hits that specific error, so a
/// machine where direct access does work never sees a password prompt.
///
/// `writeElevated` uses `sudo -A dd`, not `osascript ... do shell script
/// ... with administrator privileges` — that was tried first, but even
/// with Full Disk Access granted to both this app and dd, it still hit
/// EPERM writing to a raw whole-disk node. `AuthorizationExecuteWithPrivileges`
/// / `security_authtrampoline` (what AppleScript's "administrator
/// privileges" uses under the hood) apparently applies an extra check
/// beyond what a plain `sudo` does — confirmed by `sudo dd` from an
/// interactive terminal working immediately with no extra grants at all.
/// `sudo -A` reproduces that same plain-sudo path while still prompting
/// via a native macOS dialog (through a generated askpass helper script)
/// rather than this app ever handling the credential itself — essentially
/// the original Python app's `sudo -A dd` (see utils/sudo_askpass.py),
/// which turns out to have been sidestepping exactly this.
public enum RawDeviceWriter {
    public static func write(
        imageAt sourcePath: URL,
        authorization: RawWriteAuthorization,
        chunkSize: Int = 4 * 1024 * 1024,
        progress: @escaping (Double) -> Void = { _ in },
        log: (String) -> Void = { _ in }
    ) throws -> Int64 {
        do {
            return try writeDirect(imageAt: sourcePath, authorization: authorization, chunkSize: chunkSize, progress: progress)
        } catch RawWriteError.openFailed(_, let err) where err == EACCES {
            log("Direct write to \(authorization.rawDevicePath) denied (permission) \u{2014} retrying with administrator privileges\u{2026}")
            return try writeElevated(imageAt: sourcePath, authorization: authorization, progress: progress, log: log)
        }
    }

    private static func writeDirect(
        imageAt sourcePath: URL,
        authorization: RawWriteAuthorization,
        chunkSize: Int,
        progress: (Double) -> Void
    ) throws -> Int64 {
        let fm = FileManager.default
        guard fm.fileExists(atPath: sourcePath.path) else {
            throw RawWriteError.sourceMissing(sourcePath.path)
        }
        let totalBytes = (try? fm.attributesOfItem(atPath: sourcePath.path)[.size] as? Int64) ?? nil

        guard let source = FileHandle(forReadingAtPath: sourcePath.path) else {
            throw RawWriteError.sourceMissing(sourcePath.path)
        }
        defer { try? source.close() }

        let fd = open(authorization.rawDevicePath, O_WRONLY)
        guard fd >= 0 else {
            throw RawWriteError.openFailed(path: authorization.rawDevicePath, errno: errno)
        }
        defer { close(fd) }

        var totalWritten: Int64 = 0
        while true {
            let chunk = try source.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { break }
            let written = chunk.withUnsafeBytes { buf -> Int in
                Foundation.write(fd, buf.baseAddress, buf.count)
            }
            guard written == chunk.count else {
                throw RawWriteError.shortWrite(expected: chunk.count, actual: written, errno: errno)
            }
            totalWritten += Int64(written)
            if let totalBytes, totalBytes > 0 {
                progress(Double(totalWritten) / Double(totalBytes))
            }
        }

        guard fsync(fd) == 0 else {
            throw RawWriteError.fsyncFailed(errno: errno)
        }
        return totalWritten
    }

    /// Runs `dd` as root via `sudo -A`, with `SUDO_ASKPASS` pointed at a
    /// small generated script that shows a native macOS password dialog
    /// (via `osascript display dialog ... with hidden answer`) rather
    /// than this app ever handling the credential itself. `sudo`'s own
    /// prompt has no path here anyway since this process has no
    /// controlling terminal; `-A` forces the askpass path unconditionally
    /// instead of trying (and failing) to write a prompt to a tty that
    /// doesn't exist. Neither sudo nor dd goes through a shell here --
    /// both run via a plain argv array -- so no command-line quoting is
    /// needed for their arguments.
    private static func writeElevated(
        imageAt sourcePath: URL,
        authorization: RawWriteAuthorization,
        progress: @escaping (Double) -> Void,
        log: (String) -> Void
    ) throws -> Int64 {
        let fm = FileManager.default
        guard fm.fileExists(atPath: sourcePath.path) else {
            throw RawWriteError.sourceMissing(sourcePath.path)
        }

        progress(0)

        // Root is NOT exempt from TCC's per-app protection of special
        // folders (Documents, Desktop, Downloads, ...) — a privileged `dd`
        // reading `sourcePath` directly gets EPERM there even though this
        // app itself already has permission to read it (that's how it got
        // built in the first place). Staging a copy under the system temp
        // directory, which TCC doesn't protect, sidesteps that: the copy
        // is made by this unprivileged process using its own already-
        // granted access, and the privileged dd only ever touches that
        // staged copy plus the raw device, never the original location.
        let stagingPath = fm.temporaryDirectory.appendingPathComponent("bookmaster-write-\(UUID().uuidString).img")
        log("Staging a copy of \(sourcePath.lastPathComponent) for the privileged write\u{2026}")
        try fm.copyItem(at: sourcePath, to: stagingPath)
        defer { try? fm.removeItem(at: stagingPath) }

        // rawDevicePath already passed the ^/dev/rdisk[0-9]+$ allowlist
        // (digits/letters/slashes only), so embedding it directly in this
        // AppleScript double-quoted string is safe without a general
        // escaping helper -- it cannot contain a `"` or `\`.
        let askpassPath = fm.temporaryDirectory.appendingPathComponent("bookmaster-askpass-\(UUID().uuidString).sh")
        let askpassScript = """
        #!/bin/sh
        osascript -e 'display dialog "BookMaster needs administrator privileges to write to \(authorization.rawDevicePath)." default answer "" with hidden answer buttons {"Cancel", "OK"} default button "OK" with icon caution' -e 'text returned of result'
        """
        try askpassScript.write(to: askpassPath, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: askpassPath.path)
        defer { try? fm.removeItem(at: askpassPath) }

        log("Requesting administrator privileges to write \(authorization.rawDevicePath)\u{2026}")

        var env = ProcessInfo.processInfo.environment
        env["SUDO_ASKPASS"] = askpassPath.path
        let totalBytes = (try? fm.attributesOfItem(atPath: stagingPath.path)[.size] as? Int64) ?? nil

        try runPrivilegedDD(
            sourcePath: stagingPath.path,
            devicePath: authorization.rawDevicePath,
            environment: env,
            totalBytes: totalBytes,
            progress: progress
        )

        progress(1)
        return totalBytes ?? 0
    }

    /// Runs `sudo -A dd ... status=progress` directly via `Process` (not
    /// `Shell.run`, which only returns once the whole command has exited)
    /// so dd's own periodic transfer updates on stderr can be read live
    /// and turned into real progress ticks, instead of the single
    /// start/finish jump a fully-buffered run would be limited to.
    ///
    /// macOS dd's `status=progress` writes updates like
    /// `123456789 bytes (123 MB, 118 MiB) transferred 1.002s, 118 MB/s`
    /// to stderr roughly once a second, each overwriting the last via a
    /// carriage return rather than a newline (confirmed empirically --
    /// this isn't documented behavior to rely on blindly). The final
    /// summary lines (`N+0 records in` / `N+0 records out` / total bytes)
    /// are newline-terminated as usual, so splitting on either `\r` or
    /// `\n` covers both.
    private static func runPrivilegedDD(
        sourcePath: String,
        devicePath: String,
        environment: [String: String],
        totalBytes: Int64?,
        progress: @escaping (Double) -> Void
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["-A", "/bin/dd", "if=\(sourcePath)", "of=\(devicePath)", "bs=4m", "conv=fsync", "status=progress"]
        process.environment = environment

        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = Pipe()

        var stderrText = Data()
        var pendingSegment = Data()
        let doneSemaphore = DispatchSemaphore(value: 0)

        // All buffer/progress-callback access happens inside this handler,
        // which the underlying dispatch source serializes -- the
        // semaphore signal on EOF is what lets the code after
        // process.run() safely read stderrText afterward without a lock.
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                doneSemaphore.signal()
                return
            }
            stderrText.append(chunk)
            pendingSegment.append(chunk)
            while let separatorIndex = pendingSegment.firstIndex(where: { $0 == 0x0D || $0 == 0x0A }) {
                let segment = pendingSegment[..<separatorIndex]
                pendingSegment.removeSubrange(...separatorIndex)
                guard let text = String(data: segment, encoding: .utf8),
                      let totalBytes, totalBytes > 0,
                      let bytesSoFar = parseDDProgressBytes(text) else { continue }
                progress(min(Double(bytesSoFar) / Double(totalBytes), 1.0))
            }
        }

        try process.run()
        doneSemaphore.wait()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw RawWriteError.elevatedWriteFailed(String(data: stderrText, encoding: .utf8) ?? "")
        }
    }

    private static let ddProgressBytesPattern = try! NSRegularExpression(pattern: #"^(\d+) bytes"#)

    /// Parses a single dd `status=progress` line, e.g.
    /// `123456789 bytes (123 MB, 118 MiB) transferred 1.002s, 118 MB/s`,
    /// returning the leading byte count -- or nil for anything else,
    /// notably dd's final `N+0 records in`/`N+0 records out` summary
    /// lines, which this must silently ignore rather than misparse. Not
    /// private, so BookMasterTests can verify it against real captured
    /// dd output rather than only by inspection.
    static func parseDDProgressBytes(_ line: String) -> Int64? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let match = ddProgressBytesPattern.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
              let numberRange = Range(match.range(at: 1), in: trimmed) else { return nil }
        return Int64(trimmed[numberRange])
    }
}
