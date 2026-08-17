import SwiftUI

/// Thumbnail cover art for a book, resolved by SKU via BookCoverCatalog
/// -- a bundled, static lookup (see book_covers.csv), not a network
/// query, so resolving the URL is just a computed property; AsyncImage
/// below still does its own network fetch to actually load the image.
/// Used both where Create Master looks a book up from ISBN and where
/// Verify Master looks one up from a drive's detected SKU/ISBN.
struct BookCoverView: View {
    let sku: String?
    var width: CGFloat = 64

    private var imageURL: URL? {
        guard let sku else { return nil }
        return BookCoverCatalog.coverImageURL(forSKU: sku)
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.gray.opacity(0.12))
            if let imageURL {
                AsyncImage(url: imageURL) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: width, height: width * 1.4)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.gray.opacity(0.2)))
    }

    private var placeholder: some View {
        Image(systemName: "book.closed")
            .foregroundStyle(.secondary)
    }
}
