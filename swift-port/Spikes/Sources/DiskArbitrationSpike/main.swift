// Spike 1: DiskArbitration-based USB mount/unmount detection.
//
// Replaces the Python USBHub's psutil polling loop + shelling out to
// `diskutil`/`system_profiler` with native, event-driven callbacks.
//
// Run with: swift run DiskArbitrationSpike
// Then plug/unplug a USB drive and watch events print. Ctrl+C to exit.

import DiskArbitration
import Foundation

setbuf(stdout, nil) // unbuffered, so events show up immediately when piped/redirected

func describe(_ disk: DADisk) -> String {
    guard let desc = DADiskCopyDescription(disk) as? [String: Any] else {
        return "<no description>"
    }

    let bsdName = DADiskGetBSDName(disk).map { String(cString: $0) } ?? "-"
    let isRemovable = desc[kDADiskDescriptionMediaRemovableKey as String] as? Bool ?? false
    let isWhole = desc[kDADiskDescriptionMediaWholeKey as String] as? Bool ?? false
    let isEjectable = desc[kDADiskDescriptionMediaEjectableKey as String] as? Bool ?? false
    let volumeName = desc[kDADiskDescriptionVolumeNameKey as String] as? String ?? "-"
    let volumePath = (desc[kDADiskDescriptionVolumePathKey as String] as? URL)?.path ?? "-"
    let protocolName = desc[kDADiskDescriptionDeviceProtocolKey as String] as? String ?? "-"
    let size = desc[kDADiskDescriptionMediaSizeKey as String] as? Int ?? -1

    return "bsd=\(bsdName) whole=\(isWhole) removable=\(isRemovable) ejectable=\(isEjectable) " +
           "protocol=\(protocolName) size=\(size) volume=\(volumeName) path=\(volumePath)"
}

// This is the safety-relevant predicate a real port would centralize and
// reuse for every write decision: only ever treat a disk as a candidate
// if it is BOTH removable and connected over USB. `isWhole` distinguishes
// the whole-disk object (what you'd target for a raw write) from its
// partition/slice children, which also generate their own appear events.
func isCandidateUSBWholeDisk(_ disk: DADisk) -> Bool {
    guard let desc = DADiskCopyDescription(disk) as? [String: Any] else { return false }
    let isRemovable = desc[kDADiskDescriptionMediaRemovableKey as String] as? Bool ?? false
    let isWhole = desc[kDADiskDescriptionMediaWholeKey as String] as? Bool ?? false
    let protocolName = desc[kDADiskDescriptionDeviceProtocolKey as String] as? String ?? ""
    return isRemovable && isWhole && protocolName == "USB"
}

let session = DASessionCreate(kCFAllocatorDefault)!
DASessionSetDispatchQueue(session, DispatchQueue.main)

let appearedCallback: DADiskAppearedCallback = { disk, _ in
    let flagged = isCandidateUSBWholeDisk(disk) ? " <-- candidate for write" : ""
    print("[appeared]    \(describe(disk))\(flagged)")
}

let disappearedCallback: DADiskDisappearedCallback = { disk, _ in
    print("[disappeared] \(describe(disk))")
}

DARegisterDiskAppearedCallback(session, nil, appearedCallback, nil)
DARegisterDiskDisappearedCallback(session, nil, disappearedCallback, nil)

print("DiskArbitration spike listening for disk arrival/departure (Ctrl+C to exit).")
print("Currently mounted volumes:")
if let entries = try? FileManager.default.contentsOfDirectory(atPath: "/Volumes") {
    for entry in entries.sorted() { print("  - \(entry)") }
}
print("")

RunLoop.main.run()
