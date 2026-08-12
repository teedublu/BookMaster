import SwiftUI

/// Thumbnail cover art for a book, resolved by SKU via BookCoverLookup.
/// Used both where Create Master looks a book up from ISBN and where
/// Verify Master looks one up from a drive's detected SKU/ISBN -- `.task(id:
/// sku)` re-triggers the lookup (and cancels any in-flight one) whenever
/// the SKU changes, and clears back to the placeholder for a nil/empty SKU.
struct BookCoverView: View {
    let sku: String?
    var width: CGFloat = 64

    @State private var imageURL: URL?

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
        .task(id: sku) {
            imageURL = nil
            guard let sku, !sku.isEmpty else { return }
            imageURL = await BookCoverLookup.coverImageURL(forSKU: sku)
        }
    }

    private var placeholder: some View {
        Image(systemName: "book.closed")
            .foregroundStyle(.secondary)
    }
}
