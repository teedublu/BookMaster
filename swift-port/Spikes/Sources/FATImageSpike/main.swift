// Spike 3: hdiutil-based FAT image authoring.
//
// Proves out replacing `mkfs.vfat` + `mtools` (Homebrew-only, not part of
// the macOS SDK) with native `hdiutil`, to build the FAT-formatted disk
// image that later gets written byte-for-byte to a USB drive.
//
// Steps: create a blank FAT image -> attach it (mounted, -nobrowse) ->
// copy files in via FileManager -> detach -> verify by re-attaching
// read-only and reading the files back.
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

let fm = FileManager.default
let workDir = fm.temporaryDirectory.appendingPathComponent("fatimage-spike-\(UUID().uuidString)")
try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
let imagePath = workDir.appendingPathComponent("TESTVOL.dmg").path
let volumeLabel = "TESTVOL"

print("Work dir: \(workDir.path)")

// 1) Create a blank 20MB FAT32 image (superfloppy layout — no partition
//    map — to mirror the direct-FAT-on-raw-device layout mkfs.vfat produces).
print("\n[1/5] Creating blank FAT image via hdiutil create ...")
try run("/usr/bin/hdiutil", [
    "create",
    "-size", "20m",
    "-fs", "MS-DOS FAT32",
    "-layout", "NONE",
    "-volname", volumeLabel,
    imagePath,
])
print("  created \(imagePath)")

// 2) Attach (mount) it so we can copy files in with FileManager.
print("\n[2/5] Attaching image (mounted, -nobrowse) ...")
let attachOut = try run("/usr/bin/hdiutil", ["attach", "-nobrowse", imagePath])
guard let mountPoint = attachedMountPoint(fromHdiutilAttachOutput: attachOut),
      let device = devicePath(fromHdiutilAttachOutput: attachOut) else {
    throw ShellError(description: "could not parse mount point / device from hdiutil attach output:\n\(attachOut)")
}
print("  mounted at \(mountPoint) (device \(device))")

// 3) Copy test "master" files in via plain FileManager — no mtools needed.
print("\n[3/5] Copying test files via FileManager ...")
let mountURL = URL(fileURLWithPath: mountPoint)
try "test book contents".write(to: mountURL.appendingPathComponent("bookInfo.txt"), atomically: true, encoding: .utf8)
try fm.createDirectory(at: mountURL.appendingPathComponent("tracks"), withIntermediateDirectories: true)
try "fake-track-bytes".write(to: mountURL.appendingPathComponent("tracks/track01.mp3"), atomically: true, encoding: .utf8)
print("  wrote bookInfo.txt and tracks/track01.mp3")

// 4) Detach cleanly.
print("\n[4/5] Detaching ...")
try run("/usr/bin/hdiutil", ["detach", device])
print("  detached")

// 5) Re-attach read-only and verify contents round-trip, then clean up.
print("\n[5/5] Re-attaching read-only to verify round-trip ...")
let verifyAttachOut = try run("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", imagePath])
guard let verifyMount = attachedMountPoint(fromHdiutilAttachOutput: verifyAttachOut),
      let verifyDevice = devicePath(fromHdiutilAttachOutput: verifyAttachOut) else {
    throw ShellError(description: "could not parse mount point on verify attach:\n\(verifyAttachOut)")
}
let verifyURL = URL(fileURLWithPath: verifyMount)
let readBack = try String(contentsOf: verifyURL.appendingPathComponent("bookInfo.txt"), encoding: .utf8)
let trackExists = fm.fileExists(atPath: verifyURL.appendingPathComponent("tracks/track01.mp3").path)
try run("/usr/bin/hdiutil", ["detach", verifyDevice])

let imageSize = (try? fm.attributesOfItem(atPath: imagePath)[.size] as? Int) ?? nil

print("\nResult:")
print("  bookInfo.txt round-trip: \(readBack == "test book contents" ? "OK" : "MISMATCH (\(readBack))")")
print("  tracks/track01.mp3 present: \(trackExists ? "OK" : "MISSING")")
print("  final image size on disk: \(imageSize.map(String.init) ?? "unknown") bytes")
print("\nNOTE: this .dmg is a UDIF container, not yet a flat/raw byte image.")
print("Before this can replace a direct dd-to-device write, it needs")
print("`hdiutil convert -format UFBI` (or equivalent) to produce a flat")
print("raw image whose bytes are exactly the FAT filesystem — see README.")

try? fm.removeItem(at: workDir)
