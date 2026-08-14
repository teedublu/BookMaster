import Foundation

/// Generates placeholder book metadata for exercising Create Master
/// without a real catalog entry on hand -- an ISBN-13 starting with the
/// non-issued 999 prefix (so it's immediately recognizable as test data
/// and can never collide with a real book) with a correctly computed
/// check digit, and a SKU in the `XX-<5 digits>-<4 letters>` shape.
public enum TestDataGenerator {
    public struct BookData {
        public let isbn: String
        public let sku: String
        public let title: String
        public let author: String
        public let fileCount: Int
    }

    public static func generate() -> BookData {
        BookData(
            isbn: randomISBN13(),
            sku: randomSKU(),
            title: "Test Book",
            author: "Test Author",
            fileCount: Int.random(in: 3...18)
        )
    }

    /// 999 (unused as a real ISBN prefix) + 9 random digits + a
    /// correctly computed ISBN-13 check digit.
    private static func randomISBN13() -> String {
        var digits = [9, 9, 9] + (0..<9).map { _ in Int.random(in: 0...9) }
        let weightedSum = digits.enumerated().reduce(0) { sum, indexed in
            let (index, digit) = indexed
            return sum + digit * (index.isMultiple(of: 2) ? 1 : 3)
        }
        digits.append((10 - (weightedSum % 10)) % 10)
        return digits.map(String.init).joined()
    }

    private static func randomSKU() -> String {
        let number = Int.random(in: 10000...99999)
        let letters = (0..<4).map { _ in String(UnicodeScalar(UInt8.random(in: 65...90))) }.joined()
        return "XX-\(number)-\(letters)"
    }
}
