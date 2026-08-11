import Foundation

/// Ports master.py's calculate_encoding_for_drive_capacity(): if a
/// track collection's estimated size exceeds 90% of the drive's usable
/// capacity (10% safety margin reserved for filesystem/slack), reduce
/// the encoding bitrate proportionally, floored at a minimum bitrate,
/// never increased above the original.
public enum BitrateFitting {
    public static let minimumBitRate = 32000

    public static func fitBitRate(
        currentSizeBytes: Int64,
        currentBitRate: Int,
        maxDriveSizeBytes: Int64,
        safetyMargin: Double = 0.1
    ) -> Int {
        let usableBytes = Double(maxDriveSizeBytes) * (1 - safetyMargin)
        guard Double(currentSizeBytes) > usableBytes, usableBytes > 0 else {
            return currentBitRate
        }
        let reductionFactor = usableBytes / Double(currentSizeBytes)
        let required = Int(Double(currentBitRate) * reductionFactor)
        return max(minimumBitRate, min(required, currentBitRate))
    }
}
