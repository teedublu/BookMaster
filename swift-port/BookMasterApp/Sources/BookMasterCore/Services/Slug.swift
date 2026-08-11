import Foundation

/// Minimal stand-in for Python's `python-slugify`: lowercase, collapse
/// runs of non-alphanumeric characters to a single hyphen, trim leading/
/// trailing hyphens. The values this app actually slugifies (ISBN
/// digits, SKU suffixes) are already clean alphanumerics, so this
/// covers the real inputs without pulling in a transliteration library
/// for the general case Python's slugify handles but this app never hits.
enum Slug {
    static func make(_ input: String) -> String {
        var result = ""
        var lastWasSeparator = false
        for scalar in input.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                result.unicodeScalars.append(scalar)
                lastWasSeparator = false
            } else if !lastWasSeparator {
                result.append("-")
                lastWasSeparator = true
            }
        }
        while result.hasPrefix("-") { result.removeFirst() }
        while result.hasSuffix("-") { result.removeLast() }
        return result
    }
}
