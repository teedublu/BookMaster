// Spike 2: raw device write path prototype.
//
// Proves out the low-level mechanics (open, chunked write, fsync, verify)
// that will replace the current `dd`-to-/dev/rdiskN subprocess call.
//
// SAFETY: this spike deliberately never touches a real device node. It
// writes to a plain scratch file standing in for `/dev/rdiskN`, because
// this session has no attached USB hardware and no way for a human to
// confirm which physical drive is safe to sacrifice. The device-targeting
// guard below (`isAllowedRawTarget`) is exercised only against path
// strings, not real hardware. Validating this against a real device MUST
// happen with a human present, on a drive they've explicitly designated
// as scratch — see README.md in this directory.
//
// Run with: swift run RawWriteSpike

import Foundation
import CryptoKit

// A hard-coded allowlist pattern, exactly the kind of guard the earlier
// code review flagged as missing from the Python implementation (which
// targeted devices via a regex over `/dev/diskN` strings with no
// independent confirmation the device is actually removable/USB).
//
// This is necessary but NOT sufficient on its own — the real port must
// additionally cross-check the target against DiskArbitration's live
// description (removable == true, protocol == "USB", isWhole == true;
// see DiskArbitrationSpike's `isCandidateUSBWholeDisk`) immediately
// before writing, not just pattern-match the path string once earlier
// in the flow. Two independent checks close to the point of no return.
func isAllowedRawTargetPattern(_ path: String) -> Bool {
    // Only the whole raw disk device, e.g. /dev/rdisk4 — never a slice
    // (/dev/rdisk4s1) and never the buffered (non-"r") node.
    let pattern = #"^/dev/rdisk[0-9]+$"#
    return path.range(of: pattern, options: .regularExpression) != nil
}

struct WriteError: Error, CustomStringConvertible {
    let description: String
}

func sha256Hex(ofFileAt path: String) throws -> String {
    let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
    defer { try? handle.close() }
    var hasher = SHA256()
    while true {
        let chunk = try handle.read(upToCount: 4 * 1024 * 1024) ?? Data()
        if chunk.isEmpty { break }
        hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

/// Writes `sourcePath`'s bytes to `targetPath` in fixed-size chunks,
/// fsyncing at the end — the same shape as a `dd bs=4m` invocation, but
/// as native Swift/POSIX calls instead of shelling out.
func rawCopy(from sourcePath: String, to targetPath: String, chunkSize: Int = 4 * 1024 * 1024) throws -> Int {
    guard let source = FileHandle(forReadingAtPath: sourcePath) else {
        throw WriteError(description: "cannot open source \(sourcePath)")
    }
    defer { try? source.close() }

    let fd = open(targetPath, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
    guard fd >= 0 else {
        throw WriteError(description: "cannot open target \(targetPath): \(String(cString: strerror(errno)))")
    }
    defer { close(fd) }

    var totalWritten = 0
    while true {
        let chunk = try source.read(upToCount: chunkSize) ?? Data()
        if chunk.isEmpty { break }
        let written = chunk.withUnsafeBytes { buf -> Int in
            write(fd, buf.baseAddress, buf.count)
        }
        guard written == chunk.count else {
            throw WriteError(description: "short write: expected \(chunk.count), wrote \(written) (errno \(errno): \(String(cString: strerror(errno))))")
        }
        totalWritten += written
    }

    guard fsync(fd) == 0 else {
        throw WriteError(description: "fsync failed: \(String(cString: strerror(errno)))")
    }
    return totalWritten
}

// --- Drive the spike ---

let fm = FileManager.default
let workDir = fm.temporaryDirectory.appendingPathComponent("rawwrite-spike-\(UUID().uuidString)")
try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: workDir) }

let sourcePath = workDir.appendingPathComponent("source.img").path
let targetPath = workDir.appendingPathComponent("scratch-target.img").path

print("[1/4] Checking device-targeting guard against sample paths ...")
let samplePaths = ["/dev/rdisk4", "/dev/rdisk4s1", "/dev/disk4", "/dev/rdisk0", "not-a-device"]
for p in samplePaths {
    print("  \(p.padding(toLength: 16, withPad: " ", startingAt: 0)) allowed=\(isAllowedRawTargetPattern(p))")
}
print("  (note: /dev/rdisk0 matches the pattern but would still need the")
print("   DiskArbitration removable+USB check to be rejected in practice —")
print("   pattern matching alone is not the safety boundary.)")

print("\n[2/4] Generating 10MB pseudo-random source file ...")
var rng = SystemRandomNumberGenerator()
var sourceData = Data(count: 10 * 1024 * 1024)
sourceData.withUnsafeMutableBytes { (buf: UnsafeMutableRawBufferPointer) in
    for i in 0..<buf.count { buf[i] = UInt8.random(in: 0...255, using: &rng) }
}
try sourceData.write(to: URL(fileURLWithPath: sourcePath))
let sourceHash = try sha256Hex(ofFileAt: sourcePath)
print("  source sha256: \(sourceHash)")

print("\n[3/4] Raw-copying to scratch target (standing in for /dev/rdiskN) ...")
let start = Date()
let bytesWritten = try rawCopy(from: sourcePath, to: targetPath)
let elapsed = Date().timeIntervalSince(start)
print("  wrote \(bytesWritten) bytes in \(String(format: "%.3f", elapsed))s")

print("\n[4/4] Verifying checksum round-trip ...")
let targetHash = try sha256Hex(ofFileAt: targetPath)
print("  target sha256: \(targetHash)")
print("  \(sourceHash == targetHash ? "OK — checksums match" : "MISMATCH — write path is broken")")

if sourceHash != targetHash {
    exit(1)
}
