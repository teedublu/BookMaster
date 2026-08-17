import Foundation

/// Cover image URLs per SKU, sourced from a Shopify product export
/// (Resources/book_covers.csv, generated from a Shopify "Products"
/// export containing Title + Image Src -- that export has no SKU
/// column, so the generator joins on normalized title against
/// books.csv's own Title/SKU pairs instead, then bakes the result down
/// to a plain SKU -> URL table). Bundled and static -- replaces the
/// earlier BookCoverLookup, which queried Voxblock's Sanity CMS live
/// over the network on every lookup; that dataset is being retired.
///
/// Only 308 of books.csv's ~339 real (non-blank) rows had a clean
/// title match in the Shopify export (titles that were bundles,
/// reformatted, or simply not listed on Shopify were left out rather
/// than guessed at) -- an unmatched SKU returns nil here, same as a
/// failed lookup did before, and BookCoverView already falls back to
/// its placeholder icon for that case.
public enum BookCoverCatalog {
    public static let shared: [String: URL] = load()

    public static func coverImageURL(forSKU sku: String) -> URL? {
        guard !sku.isEmpty else { return nil }
        return shared[sku]
    }

    private static func load() -> [String: URL] {
        guard let url = Bundle.main.url(forResource: "book_covers", withExtension: "csv"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            print("WARNING: could not load bundled book_covers.csv")
            return [:]
        }
        var result: [String: URL] = [:]
        for row in CSVParser.parse(text).dropFirst() where row.count >= 2 {
            guard !row[0].isEmpty, let imageURL = URL(string: row[1]) else { continue }
            result[row[0]] = imageURL
        }
        return result
    }
}
