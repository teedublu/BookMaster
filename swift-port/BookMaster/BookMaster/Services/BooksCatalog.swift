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

/// Ports config.py's _load_books_csv(): the product catalog keyed by ISBN
/// for O(1) lookup, mirroring Python's `csv.DictReader` + dict-of-dicts.
///
/// The live source is the "Products" Google Sheet (see ProductSheet),
/// installed at runtime via `install(_:source:)`. Until a fetch
/// succeeds this starts from the last cached fetch on disk, or failing
/// that the bundled books.csv snapshot. Reads and swaps are guarded by
/// a lock because drive checks and audits read the catalog off the
/// main thread while a refresh may be installing a new one.
///
/// Note: main_window.py's _on_isbn_change() reads
/// `row.get('ExpectedFileCount', 0)`, but books.csv's column is
/// actually named "Files" — that lookup always silently fell back to 0
/// in the Python app. Fixed here to read the real column name so File
/// Count populates along with Title/Author on ISBN lookup. The live
/// sheet has since renamed it "Master Files"; `columnAliases` maps it
/// back so every consumer keeps reading "Files".
public enum BooksCatalog {
    public enum Source: Equatable {
        case bundled
        case cache(fetchedAt: Date)
        case sheet(fetchedAt: Date)
    }

    private struct State {
        var rows: [String: BookRow]
        var source: Source
    }

    private static let lock = NSLock()
    private static var state: State = initialState()

    /// Sheet column name -> the name consumers read it by.
    static let columnAliases = ["Master Files": "Files"]

    public static var shared: [String: BookRow] {
        lock.lock(); defer { lock.unlock() }
        return state.rows
    }

    public static var source: Source {
        lock.lock(); defer { lock.unlock() }
        return state.source
    }

    public static func lookup(isbn: String) -> BookRow? {
        shared[isbn]
    }

    static func install(_ rows: [String: BookRow], source: Source) {
        lock.lock(); defer { lock.unlock() }
        state = State(rows: rows, source: source)
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

    /// Cached sheet data wins over the bundled snapshot, except under
    /// XCTest, where tests assert against the bundled books.csv and must
    /// not depend on whatever this Mac last fetched.
    private static func initialState() -> State {
        if !ProductSheet.isRunningUnderTests, let cached = ProductSheet.loadCache() {
            let cachedRows = rows(fromTable: cached.values)
            if !cachedRows.isEmpty {
                return State(rows: cachedRows, source: .cache(fetchedAt: cached.fetchedAt))
            }
        }
        return State(rows: loadBundled(), source: .bundled)
    }

    private static func loadBundled() -> [String: BookRow] {
        guard let url = Bundle.main.url(forResource: "books", withExtension: "csv"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            print("WARNING: could not load bundled books.csv")
            return [:]
        }
        return parse(text)
    }

    static func parse(_ text: String) -> [String: BookRow] {
        rows(fromTable: CSVParser.parse(text))
    }

    /// Header row + data rows (a parsed CSV, or the Sheets API's
    /// `values`, which drops trailing empty cells) -> rows keyed by ISBN.
    static func rows(fromTable table: [[String]]) -> [String: BookRow] {
        guard let rawHeader = table.first else { return [:] }
        let header = rawHeader.map { $0.trimmingCharacters(in: .whitespaces) }
        var result: [String: BookRow] = [:]
        for row in table.dropFirst() {
            guard !row.isEmpty, row.contains(where: { !$0.isEmpty }) else { continue }
            var fields: [String: String] = [:]
            for (index, key) in header.enumerated() where !key.isEmpty {
                fields[key] = index < row.count ? row[index] : ""
            }
            for (alias, canonical) in columnAliases where fields[canonical] == nil {
                if let value = fields[alias] { fields[canonical] = value }
            }
            guard let isbn = fields["ISBN"]?.trimmingCharacters(in: .whitespaces), !isbn.isEmpty else { continue }
            fields["ISBN"] = isbn
            result[isbn] = BookRow(fields: fields)
        }
        return result
    }
}
