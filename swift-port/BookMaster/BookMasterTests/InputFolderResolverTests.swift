import XCTest
@testable import BookMaster

final class InputFolderResolverTests: XCTestCase {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("resolver-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testBasePathItselfContainingISBNIsReturnedDirectly() throws {
        let base = try makeTempDir().appendingPathComponent("9781234567897 - Some Book")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let found = InputFolderResolver.resolve(basePath: base, isbn: "9781234567897")
        XCTAssertEqual(found?.path, base.path)
    }

    func testFindsMatchingImmediateSubfolder() throws {
        let base = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let match = base.appendingPathComponent("9781234567897 - Some Book")
        try FileManager.default.createDirectory(at: match, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: base.appendingPathComponent("Unrelated Folder"), withIntermediateDirectories: true)

        let found = InputFolderResolver.resolve(basePath: base, isbn: "9781234567897")
        // .canonicalized(): FileManager.contentsOfDirectory resolves child
        // URLs through the /var -> /private/var firmlink while `match`
        // (built directly off temporaryDirectory) doesn't -- same
        // firmlink mismatch documented on URL.canonicalized() itself,
        // not a real path difference.
        XCTAssertEqual(found?.canonicalized().path, match.canonicalized().path)
    }

    func testDoesNotSearchBeyondImmediateSubfolders() throws {
        let base = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let nested = base.appendingPathComponent("Unrelated").appendingPathComponent("9781234567897 - Nested Too Deep")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        XCTAssertNil(InputFolderResolver.resolve(basePath: base, isbn: "9781234567897"))
    }

    func testReturnsNilWhenNoMatchFound() throws {
        let base = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base.appendingPathComponent("Something Else"), withIntermediateDirectories: true)

        XCTAssertNil(InputFolderResolver.resolve(basePath: base, isbn: "9781234567897"))
    }

    func testReturnsNilForNonexistentBasePath() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("does-not-exist-\(UUID().uuidString)")
        XCTAssertNil(InputFolderResolver.resolve(basePath: missing, isbn: "9781234567897"))
    }

    func testReturnsNilForEmptyISBN() throws {
        let base = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        XCTAssertNil(InputFolderResolver.resolve(basePath: base, isbn: ""))
    }
}
