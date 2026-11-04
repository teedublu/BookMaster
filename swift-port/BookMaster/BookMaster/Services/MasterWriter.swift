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
    public let verifiedFileCount: Int
    public let serial: String?
}

public enum MasterWriteError: Error, CustomStringConvertible {
    case couldNotMountToVerify(bsdName: String)
    case verificationFailed(problems: [String])

    public var description: String {
        switch self {
        case .couldNotMountToVerify(let bsdName):
            return "the image was written but \(bsdName) could not be mounted to verify it \u{2014} treat this block as unverified"
        case .verificationFailed(let problems):
            let shown = problems.prefix(3).joined(separator: "; ")
            let more = problems.count > 3 ? " (and \(problems.count - 3) more)" : ""
            return "write verification failed, the block does not match the image: \(shown)\(more)"
        }
    }
}

public enum MasterWriter {
    private static let expectedBitRateKbps = 96.0

    /// Ports voxmaster's writer.py `write()`: unmount, raw-write, remount
    /// and inspect what actually landed (artifact cleanup, a file-by-file
    /// comparison against the image, duration/rate estimate), record the
    /// write, eject. The write step itself (RawDeviceWriter) tries native
    /// unprivileged I/O first and only escalates -- via macOS's own
    /// admin-authentication dialog, not a stored credential -- if that's
    /// denied; see RawDeviceWriter's doc comment for why that's common.
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
        let bytesWritten = try RawDeviceWriter.write(imageAt: master.imagePath, authorization: authorization, progress: progress, log: log)
        let elapsed = max(1, Int(Date().timeIntervalSince(start).rounded()))

        let throughputImage = throughputMibS(mib: master.imageMib, elapsedSeconds: elapsed)
        let throughputUsed = throughputMibS(mib: master.usedMib, elapsedSeconds: elapsed)

        let identity = USBSerialLookup.identity(forBSDName: authorization.bsdName)
        let serial = identity?.serial
        let deviceId = try? productionLog?.upsertDevice(vid: identity?.vid ?? "", pid: identity?.pid ?? "", serial: serial ?? "UNKNOWN")
        func recordVerification(passed: Bool, fileCount: Int?, byteCount: Int64?, problems: [String]) {
            guard let productionLog, let deviceId else { return }
            try? productionLog.insertMasterWriteVerification(
                deviceId: deviceId, sku: master.sku, imgPath: master.imagePath.path,
                passed: passed, fileCount: fileCount, byteCount: byteCount, problems: problems
            )
        }

        log("Remounting to inspect written content\u{2026}")
        guard let mountPoint = try? await remountAndLocateVolume(bsdName: authorization.bsdName) else {
            let error = MasterWriteError.couldNotMountToVerify(bsdName: authorization.bsdName)
            recordVerification(passed: false, fileCount: nil, byteCount: nil, problems: [error.description])
            throw error
        }

        let (foundArtifacts, removedArtifacts, samples) = DriveVerifier.removeUnexpectedEntries(at: mountPoint)
        if foundArtifacts > 0 {
            log("Removed \(removedArtifacts)/\(foundArtifacts) unexpected artifacts: \(samples.joined(separator: ", "))")
        }

        log("Comparing every file on \(authorization.bsdName) with \(master.imagePath.lastPathComponent)\u{2026}")
        let verification = try MasterWriteVerifier.verify(imagePath: master.imagePath, writtenVolume: mountPoint, log: log)
        recordVerification(
            passed: verification.isVerified, fileCount: verification.fileCount,
            byteCount: verification.byteCount, problems: verification.problems
        )
        guard verification.isVerified else {
            for problem in verification.problems {
                log("\u{26A0}\u{FE0F} \(problem)")
            }
            throw MasterWriteError.verificationFailed(problems: verification.problems)
        }
        log("Write verified: all \(verification.fileCount) files (\(verification.byteCount) bytes) on the block match the image.")

        var trackCount = 0
        var expectedSeconds: Int?
        var encodingKbps: Double?
        let tracksPath = mountPoint.appendingPathComponent("tracks")
        if FileManager.default.fileExists(atPath: tracksPath.path) {
            trackCount = (try? FileManager.default.contentsOfDirectory(atPath: tracksPath.path).count) ?? 0
            let profile = await AudioProfiler.inspectTracksAudioProfile(tracksPath: tracksPath, fullScan: false)
            expectedSeconds = profile.durationSeconds
            encodingKbps = profile.averageKbps
        }
        let rateAnomaly = encodingKbps.map { abs($0 - expectedBitRateKbps) > 0.5 } ?? false

        if let productionLog, let deviceId {
            try? productionLog.insertWrite(
                sku: master.sku, deviceId: deviceId, diskId: "/dev/\(authorization.bsdName)",
                elapsedS: elapsed, throughputUsedMibS: throughputUsed, throughputImageMibS: throughputImage,
                trackCount: trackCount, tracksPath: tracksPath.path,
                imgPath: master.imagePath.path
            )
            // Best-effort link to the exact build that was written --
            // the most recent successful master_builds row for this
            // SKU, since ResolvedMaster doesn't carry a build id.
            let masterBuildId = (try? productionLog.latestMasterBuild(sku: master.sku))?.buildId
            try? productionLog.insertMasterWrite(
                deviceId: deviceId, masterBuildId: masterBuildId, sku: master.sku, elapsedS: elapsed,
                throughputImageMibS: throughputImage, throughputUsedMibS: throughputUsed,
                trackCountWritten: trackCount, foundArtifactCount: foundArtifacts,
                removedArtifactCount: removedArtifacts, diskId: "/dev/\(authorization.bsdName)"
            )
        }

        log("Ejecting \(authorization.bsdName)\u{2026}")
        try? Shell.run("/usr/sbin/diskutil", ["eject", "/dev/\(authorization.bsdName)"])

        return MasterWriteResult(
            sku: master.sku, bsdName: authorization.bsdName, bytesWritten: bytesWritten, elapsedSeconds: elapsed,
            throughputImageMibS: throughputImage, throughputUsedMibS: throughputUsed, trackCount: trackCount,
            expectedDurationSeconds: expectedSeconds, encodingKbps: encodingKbps, encodingRateAnomaly: rateAnomaly,
            foundArtifactCount: foundArtifacts, removedArtifactCount: removedArtifacts,
            verifiedFileCount: verification.fileCount, serial: serial
        )
    }

    static func throughputMibS(mib: Double, elapsedSeconds: Int) -> Double {
        guard elapsedSeconds > 0 else { return 0 }
        return (mib / Double(elapsedSeconds) * 100).rounded() / 100
    }

    /// Polls for the volume mounted from `bsdName` after `diskutil mountDisk`. It asks the disk itself,
    /// rather than guessing `/Volumes/<label>`: blocks that share a label (every MYO block is `VOXBLOCK`)
    /// mount as `VOXBLOCK`, `VOXBLOCK 1`, ..., so a path built from the label can be another drive, and the
    /// artifact cleanup and file comparison that follow would run against that one.
    private static func remountAndLocateVolume(bsdName: String, timeout: TimeInterval = 8) async throws -> URL? {
        try? Shell.run("/usr/sbin/diskutil", ["mountDisk", "/dev/\(bsdName)"])
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let mountPoint = mountPoint(ofBSDName: bsdName) {
                return mountPoint
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        return nil
    }

    /// Where `bsdName`'s filesystem is mounted: its first slice for an MBR image, else the whole disk
    /// for a bare-FAT one (which has no `s1`, so that query fails and falls through).
    static func mountPoint(ofBSDName bsdName: String) -> URL? {
        for device in ["\(bsdName)s1", bsdName] {
            if let output = try? Shell.run("/usr/sbin/diskutil", ["info", device]),
               let path = Shell.mountPoint(fromDiskutilInfo: output) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }
}
