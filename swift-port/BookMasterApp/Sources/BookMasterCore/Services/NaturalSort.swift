import Foundation

/// Ports Python's `natsort.natsorted`: splits each string into runs of
/// digits and non-digits, comparing digit runs numerically ("2" < "10")
/// rather than lexicographically ("10" < "2"). Matters for raw publisher
/// input filenames (chapter1.mp3 ... chapter10.mp3), which aren't
/// zero-padded the way this app's own encoded output filenames are.
enum NaturalSort {
    static func compare(_ a: String, _ b: String) -> Bool {
        let aChunks = chunks(of: a)
        let bChunks = chunks(of: b)
        for (aChunk, bChunk) in zip(aChunks, bChunks) {
            if aChunk == bChunk { continue }
            if let aNum = Int(aChunk), let bNum = Int(bChunk) {
                return aNum < bNum
            }
            return aChunk < bChunk
        }
        return aChunks.count < bChunks.count
    }

    private static func chunks(of string: String) -> [String] {
        var result: [String] = []
        var current = ""
        var currentIsDigit: Bool?
        for ch in string {
            let isDigit = ch.isNumber
            if currentIsDigit == nil || currentIsDigit == isDigit {
                current.append(ch)
            } else {
                result.append(current)
                current = String(ch)
            }
            currentIsDigit = isDigit
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

extension Sequence where Element == URL {
    func naturalSorted(by keyPath: (URL) -> String = { $0.lastPathComponent }) -> [URL] {
        sorted { NaturalSort.compare(keyPath($0), keyPath($1)) }
    }
}
