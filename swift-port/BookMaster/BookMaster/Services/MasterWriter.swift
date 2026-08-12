import Foundation

public struct MasterWriteResult: Equatable {
    public let sku: String
    public let bsdName: String
    public let bytesWritten: Int64
    public let elapsedSeconds: Int
    public let throughputImageMibS: Double
    public let throughputUsedMibS: Double
    public let trackCount: Int
    public let expectedDurationSeconds: Int?
    public let encodingKbps: Double?
    public let encodingRateAnomaly: Bool
    public let foundArtifactCount: Int
    public let removedArtifactCount: Int
    public let serial: String?
}

public enum MasterWriter {
    private static let expectedBitRateKbps = 96.0

    /// Ports voxmaster's writer.py `write()`: unmount, raw-write, remount
    /// and inspect what actually landed (artifact cleanup + duration/rate
    /// estimate, reusing DriveVerifier's exact logic), record the write,
    /// eject. Kept as native I/O throughout (RawDeviceWriter, no `sudo
    /// dd`/`pv`) matching this port's established no-privilege-escalation
    /// pattern, not a literal translation of voxmaster's subprocess calls.
    public static func write(
        master: ResolvedMaster,
        drive: USBDriveInfo,
        currentCandidates: [USBDriveInfo],
        productionLog: ProductionLog?,
        log: @escaping (String) -> Void = { _ in },
        progress: @escaping (Double) -> Void = { _ in }
    ) async throws -> MasterWriteResult {
        let authorization: RawWriteAuthorization
        switch RawWriteAuthorization.authorize(drive: drive, currentCandidates: currentCandidates) {
        case .success(let auth): authorization = auth
        case .failure(let error): throw error
        }

        log("Unmounting \(authorization.bsdName)\u{2026}")
        try? Shell.run("/usr/sbin/diskutil", ["unmountDisk", "force", "/dev/\(authorization.bsdName)"])

        log("Writing \(master.imagePath.lastPathComponent) to \(authorization.rawDevicePath)\u{2026}")
        let start = Date()
        let bytesWritten = try RawDeviceWriter.write(imageAt: master.imagePath, authorization: authorization, progress: progress)
        let elapsed = max(1, Int(Date().timeIntervalSince(start).rounded()))

        let throughputImage = throughputMibS(mib: master.imageMib, elapsedSeconds: elapsed)
        let throughputUsed = throughputMibS(mib: master.usedMib, elapsedSeconds: elapsed)

        log("Remounting to inspect written content\u{2026}")
        let mountPoint = try? await remountAndLocateVolume(bsdName: authorization.bsdName, expectedVolumeLabel: master.sku)

        var trackCount = 0
        var foundArtifacts = 0
        var removedArtifacts = 0
        var expectedSeconds: Int?
        var encodingKbps: Double?

        if let mountPoint {
            let (found, removed, samples) = DriveVerifier.removeUnexpectedEntries(at: mountPoint)
            foundArtifacts = found
            removedArtifacts = removed
            if found > 0 {
                log("Removed \(removed)/\(found) unexpected artifacts: \(samples.joined(separator: ", "))")
            }

            let tracksPath = mountPoint.appendingPathComponent("tracks")
            if FileManager.default.fileExists(atPath: tracksPath.path) {
                trackCount = (try? FileManager.default.contentsOfDirectory(atPath: tracksPath.path).count) ?? 0
                let profile = await AudioProfiler.inspectTracksAudioProfile(tracksPath: tracksPath, fullScan: false)
                expectedSeconds = profile.durationSeconds
                encodingKbps = profile.averageKbps
            }
        } else {
            log("Could not remount \(authorization.bsdName) to inspect content \u{2014} skipping artifact cleanup and duration estimate.")
        }
        let rateAnomaly = encodingKbps.map { abs($0 - expectedBitRateKbps) > 0.5 } ?? false

        let identity = USBSerialLookup.identity(forBSDName: authorization.bsdName)
        let serial = identity?.serial
        if let productionLog {
            let deviceId = try? productionLog.upsertDevice(vid: identity?.vid ?? "", pid: identity?.pid ?? "", serial: serial ?? "UNKNOWN")
            if let deviceId {
                try? productionLog.insertWrite(
                    sku: master.sku, deviceId: deviceId, diskId: "/dev/\(authorization.bsdName)",
                    elapsedS: elapsed, throughputUsedMibS: throughputUsed, throughputImageMibS: throughputImage,
                    trackCount: trackCount, tracksPath: mountPoint?.appendingPathComponent("tracks").path,
                    imgPath: master.imagePath.path
                )
            }
        }

        log("Ejecting \(authorization.bsdName)\u{2026}")
        try? Shell.run("/usr/sbin/diskutil", ["eject", "/dev/\(authorization.bsdName)"])

        return MasterWriteResult(
            sku: master.sku, bsdName: authorization.bsdName, bytesWritten: bytesWritten, elapsedSeconds: elapsed,
            throughputImageMibS: throughputImage, throughputUsedMibS: throughputUsed, trackCount: trackCount,
            expectedDurationSeconds: expectedSeconds, encodingKbps: encodingKbps, encodingRateAnomaly: rateAnomaly,
            foundArtifactCount: foundArtifacts, removedArtifactCount: removedArtifacts, serial: serial
        )
    }

    static func throughputMibS(mib: Double, elapsedSeconds: Int) -> Double {
        guard elapsedSeconds > 0 else { return 0 }
        return (mib / Double(elapsedSeconds) * 100).rounded() / 100
    }

    /// Polls for `/Volumes/<expectedVolumeLabel>` after `diskutil
    /// mountDisk` -- MasterBuilder/DiskImageBuilder/MBRImageBuilder all
    /// use the SKU as the volume label, so the mount point is
    /// deterministic in the common case rather than needing to parse
    /// `diskutil list`/DiskArbitration events for it.
    private static func remountAndLocateVolume(bsdName: String, expectedVolumeLabel: String, timeout: TimeInterval = 8) async throws -> URL? {
        try? Shell.run("/usr/sbin/diskutil", ["mountDisk", "/dev/\(bsdName)"])
        let expected = URL(fileURLWithPath: "/Volumes/\(expectedVolumeLabel)")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: expected.path) {
                return expected
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        return nil
    }
}
