import Foundation

/// A snapshot of one disk's DiskArbitration description, refreshed on
/// appear/disappear/description-changed events by USBMonitor.
///
/// Deliberately named "candidate", not "drive" — being in this list
/// means "DiskArbitration says this is a removable whole disk over
/// USB," the exact minimum bar this app's write path (Phase 4) will
/// also require before it's willing to touch a device. Nothing here
/// implies it's safe to write to; Phase 4 re-checks this same
/// classification live, immediately before writing, rather than
/// trusting a value cached this far upstream in the flow.
public struct USBDriveInfo: Identifiable, Equatable {
    public var id: String { bsdName }

    public var bsdName: String
    public var rawDevicePath: String
    public var isRemovable: Bool
    public var isEjectable: Bool
    public var isWhole: Bool
    public var protocolName: String
    public var sizeBytes: Int64
    public var mediaName: String?
    public var volumeName: String?
    public var volumeKind: String?
    public var mountPath: String?

    /// Total/available capacity of the mounted volume, if mounted.
    /// Filesystem-level info, not available from DiskArbitration's own
    /// media-level description — read via URL resource values instead
    /// of shelling out to `diskutil info`/`system_profiler` the way the
    /// Python USBDrive did.
    public var totalCapacityBytes: Int64?
    public var availableCapacityBytes: Int64?

    /// The exact safety gate: removable + whole-disk + physically USB.
    /// See Phase 0's DiskArbitrationSpike README for why `isRemovable`
    /// alone isn't sufficient (CoreSimulator volumes are removable but
    /// not USB) and why this must be re-checked live at write time
    /// rather than trusted from here.
    public var isCandidate: Bool {
        isRemovable && isWhole && protocolName == "USB"
    }

    public static func == (lhs: USBDriveInfo, rhs: USBDriveInfo) -> Bool {
        lhs.bsdName == rhs.bsdName &&
        lhs.mountPath == rhs.mountPath &&
        lhs.volumeName == rhs.volumeName &&
        lhs.availableCapacityBytes == rhs.availableCapacityBytes
    }
}
