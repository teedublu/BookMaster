import Foundation

/// The live product catalog: the "Products" Google Sheet's "Books" tab,
/// the sheet books.csv has always been exported from by hand. Fetched
/// with a service account (see GoogleServiceAccount) through the Sheets
/// API, then installed into BooksCatalog in place of the bundled
/// snapshot.
///
/// The last good fetch is cached on disk so lookups still use recent
/// data offline; BooksCatalog falls back to the bundled books.csv only
/// when there has never been a successful fetch on this Mac.
enum ProductSheet {
    static let defaultSpreadsheetID = "1BzPx1XhmZ9odLmGbJoaDkJpcauqT4Ntz2V3A9fDsQfQ"
    static let defaultTab = "Books"
    static let scope = "https://www.googleapis.com/auth/spreadsheets.readonly"

    /// Columns every catalog consumer relies on. A fetch missing any of
    /// them is rejected rather than installed.
    static let requiredColumns = ["ISBN", "SKU", "Title", "Author"]

    struct Snapshot: Codable, Equatable {
        let fetchedAt: Date
        let spreadsheetID: String
        let tab: String
        let values: [[String]]
    }

    enum FetchError: LocalizedError, Equatable {
        case notConfigured
        case http(status: Int, message: String)
        case badResponse
        case implausible(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "No service account key file set -- choose one under Import > Product Sheet."
            case .http(let status, let message):
                return "Sheets API returned HTTP \(status): \(message)"
            case .badResponse:
                return "Sheets API response could not be read."
            case .implausible(let detail):
                return "Sheet data rejected, keeping the current catalog: \(detail)"
            }
        }
    }

    static var isRunningUnderTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    // MARK: Fetch

    static func fetch(
        keyFilePath: String,
        spreadsheetID: String,
        tab: String,
        session: URLSession = .shared
    ) async throws -> Snapshot {
        let keyPath = keyFilePath.trimmingCharacters(in: .whitespaces)
        guard !keyPath.isEmpty else { throw FetchError.notConfigured }
        let account = try GoogleServiceAccount(keyFilePath: keyPath)
        let token = try await account.fetchAccessToken(scope: scope, session: session)

        var request = URLRequest(url: valuesURL(spreadsheetID: spreadsheetID, tab: tab), timeoutInterval: 30)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw FetchError.http(status: status, message: apiErrorMessage(data) ?? "no details")
        }
        return Snapshot(fetchedAt: Date(), spreadsheetID: spreadsheetID, tab: tab, values: try decodeValues(data))
    }

    /// GET spreadsheets/{id}/values/{range}. The range is the quoted tab
    /// name (whole tab), percent-encoded as a single path segment so a
    /// tab name with spaces or slashes can't break the URL.
    static func valuesURL(spreadsheetID: String, tab: String) -> URL {
        var unreserved = CharacterSet.alphanumerics
        unreserved.insert(charactersIn: "-._~")
        let quotedTab = "'\(tab.replacingOccurrences(of: "'", with: "''"))'"
        let range = quotedTab.addingPercentEncoding(withAllowedCharacters: unreserved) ?? quotedTab
        let id = spreadsheetID.addingPercentEncoding(withAllowedCharacters: unreserved) ?? spreadsheetID
        var components = URLComponents()
        components.scheme = "https"
        components.host = "sheets.googleapis.com"
        components.percentEncodedPath = "/v4/spreadsheets/\(id)/values/\(range)"
        components.queryItems = [
            URLQueryItem(name: "majorDimension", value: "ROWS"),
            // What the sheet displays (e.g. "1:18", "£12.99"), matching
            // what a CSV export of it gives -- the format books.csv and
            // every consumer of BooksCatalog already expect.
            URLQueryItem(name: "valueRenderOption", value: "FORMATTED_VALUE"),
        ]
        return components.url!
    }

    private struct ValuesResponse: Decodable {
        let values: [[String]]?
    }

    static func decodeValues(_ data: Data) throws -> [[String]] {
        guard let decoded = try? JSONDecoder().decode(ValuesResponse.self, from: data) else {
            throw FetchError.badResponse
        }
        return decoded.values ?? []
    }

    private static func apiErrorMessage(_ data: Data) -> String? {
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return (body?["error"] as? [String: Any])?["message"] as? String
    }

    // MARK: Validation

    /// Guards against installing a broken pull -- wrong tab, renamed
    /// headers, a filter view that hides most rows -- over a good
    /// catalog. `currentCount` is the size of the catalog it would
    /// replace; a result under half that size is treated as a mistake.
    static func validate(values: [[String]], rows: [String: BookRow], currentCount: Int) throws {
        let header = Set((values.first ?? []).map { $0.trimmingCharacters(in: .whitespaces) })
        let missing = requiredColumns.filter { !header.contains($0) }
        guard missing.isEmpty else {
            throw FetchError.implausible("missing column(s) \(missing.joined(separator: ", "))")
        }
        guard !rows.isEmpty else {
            throw FetchError.implausible("no rows with an ISBN")
        }
        if rows.count < currentCount / 2 {
            throw FetchError.implausible("only \(rows.count) books, the current catalog has \(currentCount)")
        }
    }

    // MARK: Cache

    static var cacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BookMasterSwift", isDirectory: true)
            .appendingPathComponent("product_sheet_cache.json")
    }

    static func loadCache(from url: URL = cacheURL) -> Snapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Snapshot.self, from: data)
    }

    static func saveCache(_ snapshot: Snapshot, to url: URL = cacheURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(snapshot).write(to: url, options: .atomic)
    }

    // MARK: Refresh

    /// Fetches the sheet, validates it, swaps it into BooksCatalog and
    /// caches it. Throws without touching the current catalog on any
    /// failure. Returns the number of books now loaded.
    @discardableResult
    static func refreshCatalog(keyFilePath: String, spreadsheetID: String, tab: String) async throws -> Int {
        let snapshot = try await fetch(keyFilePath: keyFilePath, spreadsheetID: spreadsheetID, tab: tab)
        let rows = BooksCatalog.rows(fromTable: snapshot.values)
        try validate(values: snapshot.values, rows: rows, currentCount: BooksCatalog.shared.count)
        BooksCatalog.install(rows, source: .sheet(fetchedAt: snapshot.fetchedAt))
        try? saveCache(snapshot)
        return rows.count
    }
}
