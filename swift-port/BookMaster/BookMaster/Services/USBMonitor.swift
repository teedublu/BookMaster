import DiskArbitration
import Foundation
import Combine

/// Native, event-driven USB detection — replaces the Python USBHub's
/// 2-second psutil-polling loop and its diskutil/system_profiler
/// shell-outs entirely, promoting Phase 0's DiskArbitrationSpike into
/// real app code.
///
/// Publishes only disks that currently look like a whole, removable USB
/// device (`USBDriveInfo.isCandidate`) — a narrower list than the
/// Python UI showed (which listed anything mounted under /Volumes).
/// That's a deliberate scope choice: the only thing this app writes to
/// is exactly this kind of device, so surfacing anything else in the
/// picker just invites picking the wrong thing.
@MainActor
public final class USBMonitor: ObservableObject {
    @Published public private(set) var drives: [USBDriveInfo] = []

    private var session: DASession?

    public init() {
        start()
    }

    deinit {
        if let session {
            DASessionSetDispatchQueue(session, nil)
        }
    }

    private func start() {
        guard let session = DASessionCreate(kCFAllocatorDefault) else {
            print("USBMonitor: failed to create DASession")
            return
        }
        self.session = session
        DASessionSetDispatchQueue(session, DispatchQueue.main)

        let context = Unmanaged.passUnretained(self).toOpaque()
        DARegisterDiskAppearedCallback(session, nil, USBMonitor.appearedCallback, context)
        DARegisterDiskDisappearedCallback(session, nil, USBMonitor.disappearedCallback, context)

        // A disk can appear before it's finished mounting — its volume
        // path/name show up moments later as a description-changed
        // event, not as part of the original appeared callback. Without
        // this, a freshly-inserted drive could sit in the list with no
        // capacity/volume info until something else happened to trigger
        // a refresh.
        let watchKeys = [
            kDADiskDescriptionVolumePathKey,
            kDADiskDescriptionVolumeNameKey,
        ] as CFArray
        DARegisterDiskDescriptionChangedCallback(session, nil, watchKeys, USBMonitor.changedCallback, context)
    }

    // MARK: - C-callback trampolines
    //
    // DiskArbitration callbacks are @convention(c) function pointers and
    // so cannot capture state; the instance is threaded through via the
    // `context` opaque pointer instead (Unmanaged.passUnretained in
    // start(), reconstituted here) rather than as a closure capture.

    private static let appearedCallback: DADiskAppearedCallback = { disk, context in
        guard let context else { return }
        Unmanaged<USBMonitor>.fromOpaque(context).takeUnretainedValue().handle(disk: disk)
    }

    private static let disappearedCallback: DADiskDisappearedCallback = { disk, context in
        guard let context else { return }
        Unmanaged<USBMonitor>.fromOpaque(context).takeUnretainedValue().remove(disk: disk)
    }

    private static let changedCallback: DADiskDescriptionChangedCallback = { disk, _, context in
        guard let context else { return }
        Unmanaged<USBMonitor>.fromOpaque(context).takeUnretainedValue().handle(disk: disk)
    }

    // MARK: - State updates

    private func handle(disk: DADisk) {
        guard let info = Self.describe(disk: disk) else { return }
        guard info.isCandidate else {
            // Not the whole disk itself -- almost always its partition
            // slice (isWhole false). For an MBR-partitioned master, the
            // partition is where mounting actually happens, so THIS is
            // the event that fires (appeared, the first time it's seen
            // mounted, or description-changed on an already-known one)
            // once the volume is ready -- not anything on the whole
            // disk's own description. Without re-resolving the parent
            // here, a drive whose whole-disk "appeared" callback fired
            // before its partition finished mounting (a real race on
            // hot-insert -- see partitionVolumeInfo's fallback in
            // describe()) gets stuck in `drives` with mountPath nil
            // forever: its entry never gets touched again because every
            // subsequent signal targets the partition's DADisk, which
            // isCandidate always rejects.
            guard let wholeDisk = DADiskCopyWholeDisk(disk), let wholeInfo = Self.describe(disk: wholeDisk), wholeInfo.isCandidate else {
                return
            }
            upsert(wholeInfo)
            return
        }
        upsert(info)
    }

    private func upsert(_ info: USBDriveInfo) {
        if let idx = drives.firstIndex(where: { $0.bsdName == info.bsdName }) {
            drives[idx] = info
        } else {
            drives.append(info)
        }
        drives.sort { $0.bsdName < $1.bsdName }
    }

    private func remove(disk: DADisk) {
        guard let bsdName = DADiskGetBSDName(disk).map({ String(cString: $0) }) else { return }
        drives.removeAll { $0.bsdName == bsdName }
    }

    // MARK: - Eject
    //
    // Unmount-then-eject, the same sequence Finder's eject button drives --
    // DADiskEject on a still-mounted whole disk fails with kDAReturnBusy,
    // so the volumes have to come down first. DiskArbitration's callbacks
    // are @convention(c) and can't capture the continuation directly; it's
    // boxed and threaded through via the context pointer instead, same
    // pattern as the appeared/disappeared trampolines above.

    public enum EjectError: LocalizedError {
        case sessionUnavailable
        case diskNotFound(String)
        case unmountFailed(String)
        case ejectFailed(String)

        public var errorDescription: String? {
            switch self {
            case .sessionUnavailable: return "USB monitoring session unavailable."
            case .diskNotFound(let bsdName): return "Could not find disk \(bsdName)."
            case .unmountFailed(let reason): return "Unmount failed: \(reason)"
            case .ejectFailed(let reason): return "Eject failed: \(reason)"
            }
        }
    }

    private final class EjectContext {
        let disk: DADisk
        let continuation: CheckedContinuation<Void, Error>
        init(disk: DADisk, continuation: CheckedContinuation<Void, Error>) {
            self.disk = disk
            self.continuation = continuation
        }
    }

    /// Unmounts every volume on the whole disk identified by `bsdName`,
    /// then ejects it. Safe to call for any BSD name currently in
    /// `drives` -- the disappeared callback removes it from that list
    /// once macOS confirms the eject, so no manual state update is
    /// needed here on success.
    public func eject(bsdName: String) async throws {
        guard let session else { throw EjectError.sessionUnavailable }
        guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsdName) else {
            throw EjectError.diskNotFound(bsdName)
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let ejectContext = EjectContext(disk: disk, continuation: continuation)
            let context = Unmanaged.passRetained(ejectContext).toOpaque()
            DADiskUnmount(disk, DADiskUnmountOptions(kDADiskUnmountOptionWhole), USBMonitor.unmountCallback, context)
        }
    }

    private static let unmountCallback: DADiskUnmountCallback = { disk, dissenter, context in
        guard let context else { return }
        let ejectContext = Unmanaged<EjectContext>.fromOpaque(context).takeUnretainedValue()
        if let dissenter {
            let reason = DADissenterGetStatusString(dissenter) as String? ?? "unknown error"
            Unmanaged<EjectContext>.fromOpaque(context).release()
            ejectContext.continuation.resume(throwing: EjectError.unmountFailed(reason))
            return
        }
        DADiskEject(disk, DADiskEjectOptions(kDADiskEjectOptionDefault), USBMonitor.ejectCallback, context)
    }

    private static let ejectCallback: DADiskEjectCallback = { _, dissenter, context in
        guard let context else { return }
        let ejectContext = Unmanaged<EjectContext>.fromOpaque(context).takeRetainedValue()
        if let dissenter {
            let reason = DADissenterGetStatusString(dissenter) as String? ?? "unknown error"
            ejectContext.continuation.resume(throwing: EjectError.ejectFailed(reason))
        } else {
            ejectContext.continuation.resume(returning: ())
        }
    }

    // MARK: - Description decoding

    private static func describe(disk: DADisk) -> USBDriveInfo? {
        guard let bsdName = DADiskGetBSDName(disk).map({ String(cString: $0) }) else { return nil }
        guard let desc = DADiskCopyDescription(disk) as? [String: Any] else { return nil }

        let isRemovable = desc[kDADiskDescriptionMediaRemovableKey as String] as? Bool ?? false
        let isEjectable = desc[kDADiskDescriptionMediaEjectableKey as String] as? Bool ?? false
        let isWhole = desc[kDADiskDescriptionMediaWholeKey as String] as? Bool ?? false
        let protocolName = desc[kDADiskDescriptionDeviceProtocolKey as String] as? String ?? ""
        let sizeBytes = (desc[kDADiskDescriptionMediaSizeKey as String] as? NSNumber)?.int64Value ?? 0
        let mediaName = desc[kDADiskDescriptionMediaNameKey as String] as? String
        var volumeName = desc[kDADiskDescriptionVolumeNameKey as String] as? String
        var volumeKind = desc[kDADiskDescriptionVolumeKindKey as String] as? String
        var volumeURL = desc[kDADiskDescriptionVolumePathKey as String] as? URL

        // MBR-partitioned masters (this app's default imageFormat) put
        // their FAT32 filesystem on the first partition slice, not on
        // the whole disk -- DiskArbitration's volume-level keys above
        // only ever populate on the partition's own DADisk object,
        // which isCandidate's isWhole requirement filters out of this
        // list entirely. Without this fallback, an MBR drive looks
        // permanently unmounted here (no capacity/volume/mount info,
        // Check Master disabled) even once it's actually mounted.
        if volumeURL == nil, let partition = partitionVolumeInfo(forWholeDiskBSDName: bsdName) {
            volumeName = partition.volumeName ?? volumeName
            volumeKind = partition.volumeKind ?? volumeKind
            volumeURL = partition.mountPath.map { URL(fileURLWithPath: $0) }
        }

        var total: Int64?
        var available: Int64?
        if let volumeURL {
            let values = try? volumeURL.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])
            total = values?.volumeTotalCapacity.map(Int64.init)
            available = values?.volumeAvailableCapacity.map(Int64.init)
        }

        return USBDriveInfo(
            bsdName: bsdName,
            rawDevicePath: "/dev/r\(bsdName)",
            isRemovable: isRemovable,
            isEjectable: isEjectable,
            isWhole: isWhole,
            protocolName: protocolName,
            sizeBytes: sizeBytes,
            mediaName: mediaName,
            volumeName: volumeName,
            volumeKind: volumeKind,
            mountPath: volumeURL?.path,
            totalCapacityBytes: total,
            availableCapacityBytes: available,
            serialNumber: USBSerialLookup.serialNumber(forBSDName: bsdName)
        )
    }

    private struct PartitionVolumeInfo {
        let mountPath: String?
        let volumeName: String?
        let volumeKind: String?
    }

    /// `diskutil info <bsdName>s1` -- only ever tries "s1" since this
    /// app never creates more than one partition (see MBRImageBuilder).
    /// Fails harmlessly (nil) for a bare-FAT superfloppy disk, which has
    /// no "s1" slice to query -- that layout's volume info already
    /// comes through directly on the whole disk's own DiskArbitration
    /// description, so this fallback is simply never needed there.
    private static func partitionVolumeInfo(forWholeDiskBSDName bsdName: String) -> PartitionVolumeInfo? {
        guard let output = try? Shell.run("/usr/sbin/diskutil", ["info", "\(bsdName)s1"]) else { return nil }

        func field(_ label: String) -> String? {
            for line in output.split(separator: "\n") where line.contains(label) {
                let value = line.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces)
                return (value?.isEmpty == false) ? value : nil
            }
            return nil
        }

        let mountPath = field("Mount Point:")
        guard mountPath != nil, mountPath != "Not applicable (no file system)" else { return nil }
        return PartitionVolumeInfo(
            mountPath: mountPath,
            volumeName: field("Volume Name:"),
            volumeKind: field("File System Personality:")
        )
    }
}
