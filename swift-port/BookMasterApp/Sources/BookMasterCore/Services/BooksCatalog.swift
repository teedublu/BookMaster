import Foundation

/// A minimal RFC4180-ish CSV parser: handles quoted fields (embedded
/// commas/newlines) and "" as an escaped quote. Foundation has no
/// built-in CSV parser; this is deliberately small rather than pulling
/// in a dependency for something this contained.
enum CSVParser {
    static func parse(_ text: String) -> [[String]] {
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

    private static func load() -> [String: BookRow] {
        guard let url = Bundle.module.url(forResource: "books", withExtension: "csv"),
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
