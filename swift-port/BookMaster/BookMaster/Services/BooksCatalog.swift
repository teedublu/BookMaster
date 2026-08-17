import Foundation

/// A minimal RFC4180-ish CSV parser: handles quoted fields (embedded
/// commas/newlines) and "" as an escaped quote. Foundation has no
/// built-in CSV parser; this is deliberately small rather than pulling
/// in a dependency for something this contained.
enum CSVParser {
    static func parse(_ text: String) -> [[String]] {
        // Swift's Character is a grapheme cluster, and "\r\n" composes
        // into a single one -- it matches neither the "\r" nor the "\n"
        // case below, so an unnormalized CRLF file (e.g. exported from
        // Google Sheets/Excel) would fall through to the default case
        // and never break a line at all, silently collapsing the whole
        // file into one row. Normalizing every line-ending style to a
        // bare "\n" up front keeps the per-character switch below
        // correct regardless of where the file came from.
        let text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var rows: [[String]] = []
        var currentRow: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = text.makeIterator()
        var pending: Character?

        func nextChar() -> Character? {
            if let p = pending { pending = nil; return p }
            return iterator.next()
        }

        while let ch = nextChar() {
            if inQuotes {
                if ch == "\"" {
                    if let next = nextChar() {
                        if next == "\"" {
                            field.append("\"")
                        } else {
                            inQuotes = false
                            pending = next
                        }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(ch)
                }
            } else {
                switch ch {
                case "\"":
                    inQuotes = true
                case ",":
                    currentRow.append(field)
                    field = ""
                case "\n":
                    currentRow.append(field)
                    rows.append(currentRow)
                    currentRow = []
                    field = ""
                case "\r":
                    continue
                default:
                    field.append(ch)
                }
            }
        }
        if !field.isEmpty || !currentRow.isEmpty {
            currentRow.append(field)
            rows.append(currentRow)
        }
        return rows
    }
}

public struct BookRow: Equatable {
    public let fields: [String: String]
    public subscript(_ key: String) -> String? { fields[key] }
}

/// Ports config.py's _load_books_csv(): books.csv keyed by ISBN for
/// O(1) lookup, mirroring Python's `csv.DictReader` + dict-of-dicts.
///
/// Note: main_window.py's _on_isbn_change() reads
/// `row.get('ExpectedFileCount', 0)`, but books.csv has no
/// "ExpectedFileCount" column — that lookup always silently falls back
/// to 0 in the Python app today. Faithfully NOT fixed here; this port
/// reproduces existing behavior rather than a bug it happens to notice.
public enum BooksCatalog {
    public static let shared: [String: BookRow] = load()

    public static func lookup(isbn: String) -> BookRow? {
        shared[isbn]
    }

    /// books.csv's Duration column is H:MM (hours:minutes), not the
    /// MM:SS/HH:MM:SS elapsed-time format DuplicatorLogParser deals
    /// with -- an audiobook's declared runtime is always well over a
    /// minute, so treating "01:18" as 1h18m (not 1m18s) is the only
    /// sane reading.
    public static func parseDurationSeconds(_ raw: String?) -> Int? {
        guard let raw, !raw.isEmpty else { return nil }
        let parts = raw.trimmingCharacters(in: .whitespaces).split(separator: ":").map(String.init)
        guard parts.count == 2, let hours = Int(parts[0]), let minutes = Int(parts[1]) else { return nil }
        return hours * 3600 + minutes * 60
    }

    private static func load() -> [String: BookRow] {
        guard let url = Bundle.main.url(forResource: "books", withExtension: "csv"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            print("WARNING: could not load bundled books.csv")
            return [:]
        }
        return parse(text)
    }

    static func parse(_ text: String) -> [String: BookRow] {
        let rows = CSVParser.parse(text)
        guard let header = rows.first else { return [:] }
        var result: [String: BookRow] = [:]
        for row in rows.dropFirst() {
            guard !row.isEmpty, row.contains(where: { !$0.isEmpty }) else { continue }
            var fields: [String: String] = [:]
            for (index, key) in header.enumerated() where !key.isEmpty {
                fields[key] = index < row.count ? row[index] : ""
            }
            guard let isbn = fields["ISBN"], !isbn.isEmpty else { continue }
            result[isbn] = BookRow(fields: fields)
        }
        return result
    }
}
