import Foundation

/// Minimal ID3v2.3/2.4 tag reader -- not a general-purpose ID3 library,
/// just enough to read the text frames voxmaster's
/// Track.update_mp3_tags() (see track.py) is known to write: TALB
/// (title), TPE1 (author), TIT2 (a per-track name), and a TXXX:ID
/// frame holding a base64url-obfuscated ISBN. That step deliberately
/// deletes whatever tag a file arrives with and replaces it with
/// exactly those four frames, so a correctly-processed master's tracks
/// are *expected* to carry ID3 tags. What's actually worth detecting
/// is a track still carrying something else: a frame the app never
/// writes (untouched source metadata, an encoder's own tag), or one of
/// its own frames holding the wrong value.
public enum ID3Tag {
    public struct Frame: Equatable {
        public let id: String // e.g. "TALB", or "TXXX:<desc>" for a TXXX frame
        public let text: String
    }

    /// The exact frame set Track.update_mp3_tags() writes.
    public static let knownFrameIDs: Set<String> = ["TALB", "TPE1", "TIT2", "TXXX:ID"]

    public static func hasID3v2Header(at file: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 3) else { return false }
        return header == Data("ID3".utf8)
    }

    /// ID3v1 tags live in the file's last 128 bytes, marked by a "TAG"
    /// prefix -- voxmaster never writes this format, so its presence at
    /// all (regardless of content) is already the signal; there's no
    /// frame content worth decoding from it the way there is for v2.
    public static func hasID3v1Trailer(at file: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        guard let size = try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64,
              size >= 128 else {
            return false
        }
        guard (try? handle.seek(toOffset: UInt64(size - 128))) != nil,
              let trailer = try? handle.read(upToCount: 3) else {
            return false
        }
        return trailer == Data("TAG".utf8)
    }

    /// This track's ID3v2 text frames, or [] if it has no ID3v2 tag.
    public static func readID3v2Frames(at file: URL) -> [Frame] {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 10), header.count == 10,
              header.prefix(3) == Data("ID3".utf8) else {
            return []
        }
        let majorVersion = header[header.startIndex + 3]
        let tagSize = synchsafeInt(header.suffix(4))
        guard tagSize > 0, let body = try? handle.read(upToCount: tagSize) else { return [] }
        return parseFrames(in: body, majorVersion: majorVersion)
    }

    // MARK: - Stripping (the "Clean ID3 Tags" fix)

    /// Total on-disk size (header + body) of this file's ID3v2 tag, or
    /// nil if it doesn't have one.
    static func id3v2TagTotalSize(at file: URL) -> Int? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 10), header.count == 10,
              header.prefix(3) == Data("ID3".utf8) else {
            return nil
        }
        return 10 + synchsafeInt(header.suffix(4))
    }

    /// Strips this file's ID3v2 tag (from the front) and ID3v1 trailer
    /// (from the back), leaving the raw audio payload between them
    /// untouched. Rewrites via a temp-file-then-swap so a crash or
    /// error partway through can't leave a half-stripped file behind.
    /// Returns true if the file is now untagged (whether or not it
    /// actually needed stripping).
    @discardableResult
    public static func stripTags(at file: URL) -> Bool {
        guard let totalSize = try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64 else {
            return false
        }

        let startOffset = Int64(id3v2TagTotalSize(at: file) ?? 0)
        var endOffset = totalSize
        if hasID3v1Trailer(at: file) {
            endOffset = totalSize - 128
        }
        guard startOffset > 0 || endOffset < totalSize else { return true } // nothing to strip
        guard startOffset <= endOffset else { return false } // malformed/truncated tag -- leave the file alone

        let tempURL = file.deletingLastPathComponent()
            .appendingPathComponent(".\(file.lastPathComponent).stripping-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: tempURL.path, contents: nil),
              let readHandle = try? FileHandle(forReadingFrom: file),
              let writeHandle = try? FileHandle(forWritingTo: tempURL) else {
            return false
        }

        do {
            try readHandle.seek(toOffset: UInt64(startOffset))
            var remaining = endOffset - startOffset
            let chunkSize = 1 << 20 // 1 MiB
            while remaining > 0 {
                let toRead = Int(min(Int64(chunkSize), remaining))
                guard let chunk = try readHandle.read(upToCount: toRead), !chunk.isEmpty else { break }
                try writeHandle.write(contentsOf: chunk)
                remaining -= Int64(chunk.count)
            }
            try readHandle.close()
            try writeHandle.close()
        } catch {
            try? readHandle.close()
            try? writeHandle.close()
            try? FileManager.default.removeItem(at: tempURL)
            return false
        }

        do {
            _ = try FileManager.default.replaceItemAt(file, withItemAt: tempURL)
            return true
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            return false
        }
    }

    // MARK: - Obfuscated ISBN (mirrors track.py's base64.urlsafe_b64encode)

    public static func decodeObfuscatedISBN(_ base64URLSafe: String) -> String? {
        var padded = base64URLSafe
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while padded.count % 4 != 0 { padded += "=" }
        guard let data = Data(base64Encoded: padded) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Frame parsing

    private static func parseFrames(in data: Data, majorVersion: UInt8) -> [Frame] {
        var frames: [Frame] = []
        var offset = data.startIndex
        while offset + 10 <= data.endIndex {
            let idBytes = data[offset..<(offset + 4)]
            guard let id = String(bytes: idBytes, encoding: .ascii),
                  id.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }) else {
                break
            }
            let sizeBytes = data[(offset + 4)..<(offset + 8)]
            // ID3v2.4 sizes are synchsafe (7 bits/byte); v2.3 sizes are
            // plain 32-bit big-endian -- one of the two format changes
            // between those revisions that actually affects parsing here.
            let frameSize = majorVersion >= 4 ? synchsafeInt(sizeBytes) : bigEndianInt(sizeBytes)
            let bodyStart = offset + 10
            let bodyEnd = bodyStart + frameSize
            guard frameSize > 0, bodyEnd <= data.endIndex else { break }
            let body = data[bodyStart..<bodyEnd]

            if id == "TXXX" {
                if let parsed = parseTXXXBody(body) {
                    frames.append(Frame(id: "TXXX:\(parsed.desc)", text: parsed.value))
                }
            } else if id.hasPrefix("T") {
                frames.append(Frame(id: id, text: parseTextBody(body)))
            } else {
                frames.append(Frame(id: id, text: ""))
            }
            offset = bodyEnd
        }
        return frames
    }

    private static func synchsafeInt(_ bytes: Data) -> Int {
        bytes.reduce(0) { ($0 << 7) | Int($1 & 0x7F) }
    }

    private static func bigEndianInt(_ bytes: Data) -> Int {
        bytes.reduce(0) { ($0 << 8) | Int($1) }
    }

    private static func decodeText(_ bytes: Data, encodingByte: UInt8) -> String {
        let decoded: String?
        switch encodingByte {
        case 1: decoded = String(data: bytes, encoding: .utf16)
        case 2: decoded = String(data: bytes, encoding: .utf16BigEndian)
        case 3: decoded = String(data: bytes, encoding: .utf8)
        default: decoded = String(data: bytes, encoding: .isoLatin1)
        }
        var text = decoded ?? ""
        while text.hasSuffix("\u{0}") { text.removeLast() }
        return text
    }

    private static func parseTextBody(_ body: Data) -> String {
        guard let encodingByte = body.first else { return "" }
        return decodeText(body.dropFirst(), encodingByte: encodingByte)
    }

    private static func parseTXXXBody(_ body: Data) -> (desc: String, value: String)? {
        guard let encodingByte = body.first else { return nil }
        let rest = body.dropFirst()
        let terminator = Data((encodingByte == 1 || encodingByte == 2) ? [0, 0] : [0])
        guard let termRange = rest.range(of: terminator) else { return nil }
        let desc = decodeText(rest[rest.startIndex..<termRange.lowerBound], encodingByte: encodingByte)
        let value = decodeText(rest[termRange.upperBound...], encodingByte: encodingByte)
        return (desc, value)
    }
}
