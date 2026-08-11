import Foundation

public enum RawWriteError: Error, CustomStringConvertible {
    case targetNotAllowedByPattern(String)
    case targetNotCurrentlyACandidate(String)
    case sourceMissing(String)
    case openFailed(path: String, errno: Int32)
    case shortWrite(expected: Int, actual: Int, errno: Int32)
    case fsyncFailed(errno: Int32)

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
/// round-trip).
///
/// NOT ported: the Python version's `sudo -A dd ...` privilege
/// escalation (see `utils/sudo_askpass.py`). Shelling out to `sudo` from
/// a GUI app is not something to carry forward as-is into a signed,
/// distributed macOS app — the right replacement is a proper
/// authorized helper (SMJobBless/XPC, or an AuthorizationServices
/// prompt), which needs real signing infrastructure and belongs in
/// Phase 9 packaging, not here. In practice, macOS often grants the
/// logged-in console user direct read/write on a removable disk's
/// device node without elevation (unlike internal disks) — this writer
/// just attempts the direct POSIX open/write and surfaces whatever
/// `errno` comes back (e.g. EACCES) rather than assuming either way.
public enum RawDeviceWriter {
    public static func write(
        imageAt sourcePath: URL,
        authorization: RawWriteAuthorization,
        chunkSize: Int = 4 * 1024 * 1024,
        progress: (Double) -> Void = { _ in }
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
}
