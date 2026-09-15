import Foundation

public struct WriteVerificationResult: Equatable {
    public let fileCount: Int
    public let byteCount: Int64
    public let problems: [String]

    public var isVerified: Bool { problems.isEmpty }
}

/// Compares every file on a written master block with the same file inside the image it was written from.
public enum MasterWriteVerifier {
    public static func verify(
        imagePath: URL, writtenVolume: URL, log: @escaping (String) -> Void = { _ in }
    ) throws -> WriteVerificationResult {
        try MasterContentAuditor.withMountedImage(imagePath, log: log) { imageRoot in
            compare(expectedRoot: imageRoot, actualRoot: writtenVolume)
        }
    }

    static func compare(expectedRoot: URL, actualRoot: URL, chunkSize: Int = 4 * 1024 * 1024) -> WriteVerificationResult {
        let expectedFiles = masterFiles(under: expectedRoot)
        let actualFiles = masterFiles(under: actualRoot)
        var problems: [String] = []
        var byteCount: Int64 = 0

        for path in expectedFiles.sorted() {
            guard actualFiles.contains(path) else {
                problems.append("\(path): missing from the block")
                continue
            }
            do {
                let result = try compareFile(
                    expectedRoot.appendingPathComponent(path), actualRoot.appendingPathComponent(path), chunkSize: chunkSize
                )
                byteCount += result.comparedBytes
                if let problem = result.problem {
                    problems.append("\(path): \(problem)")
                }
            } catch {
                problems.append("\(path): could not be read back (\(error.localizedDescription))")
            }
        }
        for path in actualFiles.subtracting(expectedFiles).sorted() {
            problems.append("\(path): on the block but not in the image")
        }
        return WriteVerificationResult(fileCount: expectedFiles.count, byteCount: byteCount, problems: problems)
    }

    // RawDirectoryLister, because Foundation's listings silently skip "._*" files.
    private static func masterFiles(under root: URL) -> Set<String> {
        let fm = FileManager.default
        return Set(RawDirectoryLister.allEntriesRecursively(at: root).filter { path in
            guard !DriveVerifier.isUnexpectedEntry(path) else { return false }
            var isDirectory: ObjCBool = false
            return fm.fileExists(atPath: root.appendingPathComponent(path).path, isDirectory: &isDirectory) && !isDirectory.boolValue
        })
    }

    private static func compareFile(_ expected: URL, _ actual: URL, chunkSize: Int) throws -> (comparedBytes: Int64, problem: String?) {
        let expectedHandle = try FileHandle(forReadingFrom: expected)
        defer { try? expectedHandle.close() }
        let actualHandle = try FileHandle(forReadingFrom: actual)
        defer { try? actualHandle.close() }

        var offset: Int64 = 0
        var differingBytes: Int64 = 0
        var firstDifference: Int64?
        while true {
            let expectedChunk = try expectedHandle.read(upToCount: chunkSize) ?? Data()
            let actualChunk = try actualHandle.read(upToCount: chunkSize) ?? Data()
            let common = min(expectedChunk.count, actualChunk.count)
            if common == 0 { break }
            if expectedChunk.prefix(common) != actualChunk.prefix(common) {
                expectedChunk.withUnsafeBytes { (expectedBytes: UnsafeRawBufferPointer) in
                    actualChunk.withUnsafeBytes { (actualBytes: UnsafeRawBufferPointer) in
                        for i in 0..<common where expectedBytes[i] != actualBytes[i] {
                            firstDifference = firstDifference ?? offset + Int64(i)
                            differingBytes += 1
                        }
                    }
                }
            }
            offset += Int64(common)
            if expectedChunk.count != actualChunk.count { break }
        }

        var details: [String] = []
        if let firstDifference {
            details.append("\(differingBytes) bytes differ from the image, starting at byte \(firstDifference)")
        }
        let expectedSize = try fileSize(expected)
        let actualSize = try fileSize(actual)
        if expectedSize != actualSize {
            details.append("\(actualSize) bytes on the block but \(expectedSize) in the image")
        }
        return (offset, details.isEmpty ? nil : details.joined(separator: "; "))
    }

    private static func fileSize(_ url: URL) throws -> Int64 {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }
}
