import Foundation

/// Looks up a book's cover image URL from the "BookData" Sanity CMS
/// (project h2okhvxc, dataset "production") that already powers the
/// Voxblock Shopify store, keyed by SKU -- the same identifier space
/// books.csv/BooksCatalog and DriveVerifier's detected SKU already use.
///
/// Deliberately NOT using that dataset's `book` document type: its
/// `isbn`/`coverImage` fields exist in the schema but are almost
/// entirely unpopulated in practice (confirmed live: 0 of ~500+ books
/// have `isbn` set, only 1 has a `coverImage`). The Shopify-synced
/// `product`/`productVariant` documents are what's actually populated
/// (254/269 products have an image), so this joins productVariant ->
/// product by Shopify product ID and prefers the variant's own image,
/// falling back to the parent product's. The dataset is public/read-only
/// with no auth token required -- confirmed live, not assumed.
public enum BookCoverLookup {
    private static let endpoint = "https://h2okhvxc.api.sanity.io/v2023-02-07/data/query/production"

    private static let groqQuery = """
    *[_type=="productVariant"&&store.sku==$sku][0]{\
    "variantImg":store.previewImageUrl,\
    "productImg":*[_type=="product"&&store.id==^.store.productId][0].store.previewImageUrl\
    }
    """

    public static func coverImageURL(forSKU sku: String) async -> URL? {
        guard !sku.isEmpty else { return nil }
        var components = URLComponents(string: endpoint)
        components?.queryItems = [
            URLQueryItem(name: "query", value: groqQuery),
            URLQueryItem(name: "$sku", value: "\"\(sku)\""),
        ]
        guard let url = components?.url else { return nil }

        guard let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let decoded = try? JSONDecoder().decode(SanityQueryResponse.self, from: data) else {
            return nil
        }
        let urlString = decoded.result?.variantImg ?? decoded.result?.productImg
        return urlString.flatMap(URL.init(string:))
    }

    struct SanityQueryResponse: Decodable {
        let result: Result?
        struct Result: Decodable {
            let variantImg: String?
            let productImg: String?
        }
    }
}
