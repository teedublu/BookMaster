import XCTest
import Security
@testable import BookMaster

final class ProductSheetTests: XCTestCase {

    // MARK: Service account key + JWT

    /// Generates a throwaway RSA key and returns (PKCS#8 PEM, public key)
    /// -- the same "BEGIN PRIVATE KEY" shape a Google key file carries.
    private func makePKCS8Key() throws -> (pem: String, publicKey: SecKey) {
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048]
        var error: Unmanaged<CFError>?
        let privateKey = try XCTUnwrap(SecKeyCreateRandomKey(attributes as CFDictionary, &error))
        let pkcs1 = try XCTUnwrap(SecKeyCopyExternalRepresentation(privateKey, &error) as Data?)
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(privateKey))

        func tlv(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
            var length: [UInt8]
            if content.count < 0x80 {
                length = [UInt8(content.count)]
            } else {
                var n = content.count
                var bytes: [UInt8] = []
                while n > 0 { bytes.insert(UInt8(n & 0xFF), at: 0); n >>= 8 }
                length = [0x80 | UInt8(bytes.count)] + bytes
            }
            return [tag] + length + content
        }
        let rsaEncryptionOID: [UInt8] = [0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]
        let algorithm = tlv(0x30, rsaEncryptionOID + [0x05, 0x00])
        let pkcs8 = tlv(0x30, tlv(0x02, [0x00]) + algorithm + tlv(0x04, [UInt8](pkcs1)))
        let pem = "-----BEGIN PRIVATE KEY-----\n"
            + Data(pkcs8).base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
            + "\n-----END PRIVATE KEY-----\n"
        return (pem, publicKey)
    }

    private func keyFileData(pem: String, type: String = "service_account") throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "type": type,
            "client_email": "bookmaster@example.iam.gserviceaccount.com",
            "private_key": pem,
            "token_uri": "https://oauth2.googleapis.com/token",
        ])
    }

    func testAssertionIsSignedWithTheKeyFilesPrivateKey() throws {
        let (pem, publicKey) = try makePKCS8Key()
        let account = try GoogleServiceAccount(keyFileData: keyFileData(pem: pem))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let jwt = try account.makeAssertion(scope: ProductSheet.scope, now: now)

        let parts = jwt.split(separator: ".").map(String.init)
        XCTAssertEqual(parts.count, 3)

        func decode(_ part: String) throws -> Data {
            var b64 = part.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while b64.count % 4 != 0 { b64 += "=" }
            return try XCTUnwrap(Data(base64Encoded: b64))
        }
        let claims = try XCTUnwrap(JSONSerialization.jsonObject(with: decode(parts[1])) as? [String: Any])
        XCTAssertEqual(claims["iss"] as? String, "bookmaster@example.iam.gserviceaccount.com")
        XCTAssertEqual(claims["scope"] as? String, ProductSheet.scope)
        XCTAssertEqual(claims["aud"] as? String, "https://oauth2.googleapis.com/token")
        XCTAssertEqual(claims["iat"] as? Int, 1_800_000_000)
        XCTAssertEqual(claims["exp"] as? Int, 1_800_003_600)

        var error: Unmanaged<CFError>?
        let verified = SecKeyVerifySignature(
            publicKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            Data("\(parts[0]).\(parts[1])".utf8) as CFData,
            try decode(parts[2]) as CFData,
            &error
        )
        XCTAssertTrue(verified, "JWT signature should verify against the key's public half")
    }

    func testRejectsNonServiceAccountKeyFiles() throws {
        let (pem, _) = try makePKCS8Key()
        XCTAssertThrowsError(try GoogleServiceAccount(keyFileData: keyFileData(pem: pem, type: "authorized_user")))
        XCTAssertThrowsError(try GoogleServiceAccount(keyFileData: Data("not json".utf8)))
        XCTAssertThrowsError(try GoogleServiceAccount(keyFileData: keyFileData(pem: "-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----")))
    }

    // MARK: Sheets API request/response

    func testValuesURLQuotesAndEncodesTheTabName() {
        let url = ProductSheet.valuesURL(spreadsheetID: "abc123", tab: "Books")
        XCTAssertEqual(url.absoluteString,
                       "https://sheets.googleapis.com/v4/spreadsheets/abc123/values/%27Books%27?majorDimension=ROWS&valueRenderOption=FORMATTED_VALUE")
        let spaced = ProductSheet.valuesURL(spreadsheetID: "abc123", tab: "Books / Old")
        XCTAssertTrue(spaced.absoluteString.contains("/values/%27Books%20%2F%20Old%27?"))
    }

    func testDecodesValuesAndMapsMasterFilesToFiles() throws {
        // Shape of the live sheet: blank first header cell, "Master Files"
        // instead of books.csv's "Files", trailing empty cells dropped.
        let json = """
        {"range":"Books!A1:AE3","majorDimension":"ROWS","values":[
          ["","Title","SKU","ISBN","Author","Master Files","Duration"],
          ["100000","Horrible Histories: Rotten Romans","BK-43007-TDRR","9781915443007","Terry Deary","11","1:01"],
          ["100001","Alice's Adventures In Wonderland","BK-43014-LCAA"," 9781915443014 ","Lewis Carroll"]
        ]}
        """
        let values = try ProductSheet.decodeValues(Data(json.utf8))
        let rows = BooksCatalog.rows(fromTable: values)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows["9781915443007"]?["Files"], "11")
        XCTAssertEqual(rows["9781915443007"]?["Master Files"], "11")
        XCTAssertEqual(rows["9781915443014"]?["Title"], "Alice's Adventures In Wonderland")
        XCTAssertEqual(rows["9781915443014"]?["Files"], "")
        XCTAssertNoThrow(try ProductSheet.validate(values: values, rows: rows, currentCount: 3))
    }

    func testValidationRejectsMissingColumnsAndShrunkenSheets() {
        let noISBN = [["Title", "SKU", "Author"], ["A", "B", "C"]]
        XCTAssertThrowsError(try ProductSheet.validate(values: noISBN, rows: BooksCatalog.rows(fromTable: noISBN), currentCount: 0))

        let tiny = [["ISBN", "SKU", "Title", "Author"], ["1", "S", "T", "A"]]
        let rows = BooksCatalog.rows(fromTable: tiny)
        XCTAssertNoThrow(try ProductSheet.validate(values: tiny, rows: rows, currentCount: 2))
        XCTAssertThrowsError(try ProductSheet.validate(values: tiny, rows: rows, currentCount: 340))
    }

    func testCacheRoundTrips() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("product_sheet_cache.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let snapshot = ProductSheet.Snapshot(
            fetchedAt: Date(timeIntervalSince1970: 1_800_000_000),
            spreadsheetID: "abc", tab: "Books",
            values: [["ISBN", "Title"], ["123", "Hello, World"]]
        )
        try ProductSheet.saveCache(snapshot, to: url)
        XCTAssertEqual(ProductSheet.loadCache(from: url), snapshot)
    }

    func testUnderTestsTheCatalogStartsFromTheBundledSnapshot() {
        XCTAssertTrue(ProductSheet.isRunningUnderTests)
        XCTAssertEqual(BooksCatalog.source, .bundled)
    }
}
