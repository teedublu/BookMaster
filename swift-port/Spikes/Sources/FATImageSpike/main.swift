// Spike 3: hdiutil + newfs_msdos FAT image authoring.
//
// Proves out replacing `mkfs.vfat` + `mtools` (Homebrew-only, not part of
// the macOS SDK) with tools that ship on every Mac, to build the
// FAT-formatted disk image that later gets written byte-for-byte to a
// USB drive.
//
// Phase 0 finding: `hdiutil create -fs "MS-DOS FAT32"` fails with
// "Operation not permitted" on macOS 26.3 (reproduced with the bare CLI,
// independent of this code). Bisection showed the literal string
// "MS-DOS FAT32" is what's broken — "MS-DOS FAT16" and generic "MS-DOS"
// (which auto-selects FAT16/FAT32 by size, confirmed via `diskutil info`)
// both work. Rather than depend on that auto-selection threshold (it
// doesn't line up with this app's own <40MB-means-FAT16 threshold — see
// README), this spike decouples image creation from formatting instead:
//
//   1) hdiutil create -layout NONE   -- blank raw superfloppy image, no fs
//   2) hdiutil attach -nomount       -- get a device node, not yet mounted
//   3) newfs_msdos -F 16|32          -- Apple's own FAT formatter (ships
//                                        at /sbin/newfs_msdos on every Mac,
//                                        symlinked from msdos.fs), same
//                                        -F 16/32 control mkfs.vfat gave us
//   4) hdiutil detach, then hdiutil attach (mounted) -> FileManager copy
//
// Run with: swift run FATImageSpike

import Foundation

struct ShellError: Error, CustomStringConvertible {
    let description: String
}

@discardableResult
func run(_ tool: String, _ args: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = args

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    try process.run()
    process.waitUntilExit()

    let outData = stdout.fileHandleForReading.readDataToEndOfFile()
    let errData = stderr.fileHandleForReading.readDataToEndOfFile()
    let out = String(data: outData, encoding: .utf8) ?? ""
    let err = String(data: errData, encoding: .utf8) ?? ""

    guard process.terminationStatus == 0 else {
        throw ShellError(description: "\(tool) \(args.joined(separator: " ")) failed (\(process.terminationStatus)): \(err)")
    }
    return out
}

func attachedMountPoint(fromHdiutilAttachOutput output: String) -> String? {
    // hdiutil attach output looks like:
    // /dev/disk6          FDisk_partition_scheme
    // /dev/disk6s1         DOS_FAT_32                     /Volumes/TESTVOL
    for line in output.split(separator: "\n") {
        let cols = line.split(separator: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
        if let last = cols.last, last.hasPrefix("/Volumes/") {
            return last
        }
    }
    return nil
}

func devicePath(fromHdiutilAttachOutput output: String) -> String? {
    guard let firstLine = output.split(separator: "\n").first else { return nil }
    let cols = firstLine.split(separator: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
    return cols.first
}

func rawDevicePath(fromBSDDevicePath path: String) -> String {
    // /dev/disk6 -> /dev/rdisk6 (raw/character device, required by newfs_msdos)
    path.replacingOccurrences(of: "/dev/disk", with: "/dev/rdisk")
}

let fm = FileManager.default
let workDir = fm.temporaryDirectory.appendingPathComponent("fatimage-spike-\(UUID().uuidString)")
try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
let imagePath = workDir.appendingPathComponent("TESTVOL.dmg").path
let volumeLabel = "TESTVOL"
// Mirrors master.py's own threshold (fat16 below 40MB, else fat32) and
// this spike's size is picked well above it to exercise the FAT32 path,
// which is what every real master (480MB/980MB) actually uses.
let imageSizeMB = 100
let fatBits = imageSizeMB < 40 ? "16" : "32"

print("Work dir: \(workDir.path)")

// 1) Create a blank, unformatted superfloppy image (no partition map,
//    no filesystem yet).
print("\n[1/6] Creating blank raw image via hdiutil create -layout NONE ...")
try run("/usr/bin/hdiutil", [
    "create",
    "-size", "\(imageSizeMB)m",
    "-layout", "NONE",
    imagePath,
])
print("  created \(imagePath)")

// 2) Attach without mounting, to get a device node newfs_msdos can format.
print("\n[2/6] Attaching (nomount) to get a device node ...")
let nomountOut = try run("/usr/bin/hdiutil", ["attach", "-nomount", imagePath])
guard let device = devicePath(fromHdiutilAttachOutput: nomountOut) else {
    throw ShellError(description: "could not parse device from hdiutil attach -nomount output:\n\(nomountOut)")
}
let rawDevice = rawDevicePath(fromBSDDevicePath: device)
print("  device \(device) (raw \(rawDevice))")

// 3) Format directly with newfs_msdos -- exact FAT16/32 control, no
//    dependency on hdiutil's -fs string (broken for "MS-DOS FAT32") or
//    its auto-selection heuristics.
print("\n[3/6] Formatting with newfs_msdos -F \(fatBits) ...")
try run("/sbin/newfs_msdos", ["-F", fatBits, "-v", volumeLabel, rawDevice])
try run("/usr/bin/hdiutil", ["detach", device])
print("  formatted and detached")

// 4) Re-attach, now mounted, so we can copy files in with FileManager.
print("\n[4/6] Attaching (mounted, -nobrowse) ...")
let attachOut = try run("/usr/bin/hdiutil", ["attach", "-nobrowse", imagePath])
guard let mountPoint = attachedMountPoint(fromHdiutilAttachOutput: attachOut),
      let mountedDevice = devicePath(fromHdiutilAttachOutput: attachOut) else {
    throw ShellError(description: "could not parse mount point / device from hdiutil attach output:\n\(attachOut)")
}
print("  mounted at \(mountPoint) (device \(mountedDevice))")

// 5) Copy test "master" files in via plain FileManager -- no mtools needed.
print("\n[5/6] Copying test files via FileManager ...")
let mountURL = URL(fileURLWithPath: mountPoint)
try "test book contents".write(to: mountURL.appendingPathComponent("bookInfo.txt"), atomically: true, encoding: .utf8)
try fm.createDirectory(at: mountURL.appendingPathComponent("tracks"), withIntermediateDirectories: true)
try "fake-track-bytes".write(to: mountURL.appendingPathComponent("tracks/track01.mp3"), atomically: true, encoding: .utf8)
print("  wrote bookInfo.txt and tracks/track01.mp3")
try run("/usr/bin/hdiutil", ["detach", mountedDevice])

// 6) Re-attach read-only and verify contents + filesystem type round-trip.
print("\n[6/6] Re-attaching read-only to verify round-trip ...")
let verifyAttachOut = try run("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", imagePath])
guard let verifyMount = attachedMountPoint(fromHdiutilAttachOutput: verifyAttachOut),
      let verifyDevice = devicePath(fromHdiutilAttachOutput: verifyAttachOut) else {
    throw ShellError(description: "could not parse mount point on verify attach:\n\(verifyAttachOut)")
}
let verifyURL = URL(fileURLWithPath: verifyMount)
let readBack = try String(contentsOf: verifyURL.appendingPathComponent("bookInfo.txt"), encoding: .utf8)
let trackExists = fm.fileExists(atPath: verifyURL.appendingPathComponent("tracks/track01.mp3").path)
let diskutilInfo = try run("/usr/sbin/diskutil", ["info", verifyDevice])
let fsLine = diskutilInfo.split(separator: "\n").first { $0.contains("File System Personality") } ?? "unknown"
try run("/usr/bin/hdiutil", ["detach", verifyDevice])

let imageSize = (try? fm.attributesOfItem(atPath: imagePath)[.size] as? Int) ?? nil

print("\nResult:")
print("  filesystem: \(fsLine.trimmingCharacters(in: .whitespaces))")
print("  bookInfo.txt round-trip: \(readBack == "test book contents" ? "OK" : "MISMATCH (\(readBack))")")
print("  tracks/track01.mp3 present: \(trackExists ? "OK" : "MISSING")")
print("  final image size on disk: \(imageSize.map(String.init) ?? "unknown") bytes")
print("\nNOTE: this .dmg is a UDIF container, not yet a flat/raw byte image.")
print("Before this can replace a direct dd-to-device write, it needs")
print("`hdiutil convert -format UFBI` (or equivalent) to produce a flat")
print("raw image whose bytes are exactly the FAT filesystem — see README.")

try? fm.removeItem(at: workDir)
