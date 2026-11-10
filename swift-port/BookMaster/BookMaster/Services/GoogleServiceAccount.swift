import Foundation
import Security

/// Minimal Google service-account auth: signs an RS256 JWT with the key
/// file's private key and swaps it for a short-lived OAuth access token
/// (https://developers.google.com/identity/protocols/oauth2/service-account).
///
/// Same credential type the Python app's bm_registry_gsheet.py used via
/// gspread (GOOGLE_APPLICATION_CREDENTIALS), done by hand here with the
/// Security framework rather than pulling in a Google SDK for one call.
struct GoogleServiceAccount {
    let clientEmail: String
    let privateKey: SecKey
    let tokenURI: URL

    enum AuthError: LocalizedError, Equatable {
        case invalidKeyFile(String)
        case signingFailed(String)
        case tokenRequestFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidKeyFile(let detail): return "Service account key file is not usable: \(detail)"
            case .signingFailed(let detail): return "Could not sign the Google auth request: \(detail)"
            case .tokenRequestFailed(let detail): return "Google sign-in failed: \(detail)"
            }
        }
    }

    private struct KeyFile: Decodable {
        let type: String?
        let client_email: String?
        let private_key: String?
        let token_uri: String?
    }

    init(keyFileData: Data) throws {
        guard let file = try? JSONDecoder().decode(KeyFile.self, from: keyFileData) else {
            throw AuthError.invalidKeyFile("not a JSON key file")
        }
        if let type = file.type, type != "service_account" {
            throw AuthError.invalidKeyFile("type is \"\(type)\", expected \"service_account\"")
        }
        guard let email = file.client_email, !email.isEmpty else {
            throw AuthError.invalidKeyFile("missing client_email")
        }
        guard let pem = file.private_key, !pem.isEmpty else {
            throw AuthError.invalidKeyFile("missing private_key")
        }
        let tokenURI = URL(string: file.token_uri ?? "") ?? URL(string: "https://oauth2.googleapis.com/token")!
        self.clientEmail = email
        self.tokenURI = tokenURI
        self.privateKey = try Self.rsaPrivateKey(fromPEM: pem)
    }

    init(keyFilePath: String) throws {
        let expanded = (keyFilePath as NSString).expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: expanded) else {
            throw AuthError.invalidKeyFile("could not read \(expanded)")
        }
        try self.init(keyFileData: data)
    }

    // MARK: JWT

    /// The signed JWT ("assertion") Google's token endpoint exchanges for
    /// an access token. Valid for an hour from `now`, the maximum Google
    /// accepts.
    func makeAssertion(scope: String, now: Date = Date()) throws -> String {
        let issuedAt = Int(now.timeIntervalSince1970)
        let header: [String: Any] = ["alg": "RS256", "typ": "JWT"]
        let claims: [String: Any] = [
            "iss": clientEmail,
            "scope": scope,
            "aud": tokenURI.absoluteString,
            "iat": issuedAt,
            "exp": issuedAt + 3600,
        ]
        let headerPart = Self.base64URL(try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys]))
        let claimsPart = Self.base64URL(try JSONSerialization.data(withJSONObject: claims, options: [.sortedKeys]))
        let signingInput = "\(headerPart).\(claimsPart)"

        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            Data(signingInput.utf8) as CFData,
            &error
        ) as Data? else {
            let detail = error?.takeRetainedValue().localizedDescription ?? "unknown error"
            throw AuthError.signingFailed(detail)
        }
        return "\(signingInput).\(Self.base64URL(signature))"
    }

    func fetchAccessToken(scope: String, session: URLSession = .shared) async throws -> String {
        let assertion = try makeAssertion(scope: scope)
        var request = URLRequest(url: tokenURI, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=\(assertion)".utf8)

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard status == 200, let token = body?["access_token"] as? String, !token.isEmpty else {
            let detail = (body?["error_description"] as? String) ?? (body?["error"] as? String) ?? "HTTP \(status)"
            throw AuthError.tokenRequestFailed(detail)
        }
        return token
    }

    // MARK: Key parsing

    /// Google key files carry the RSA key as PKCS#8 PEM ("BEGIN PRIVATE
    /// KEY"), but SecKeyCreateWithData only takes the inner PKCS#1
    /// RSAPrivateKey -- so this unwraps the PKCS#8 envelope first. A
    /// bare PKCS#1 key ("BEGIN RSA PRIVATE KEY") is passed through.
    static func rsaPrivateKey(fromPEM pem: String) throws -> SecKey {
        let base64 = pem
            .components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("-----") }
            .joined()
            .trimmingCharacters(in: .whitespaces)
        guard let der = Data(base64Encoded: base64) else {
            throw AuthError.invalidKeyFile("private_key is not valid PEM")
        }
        guard let pkcs1 = pkcs1RSAKey(fromDER: [UInt8](der)) else {
            throw AuthError.invalidKeyFile("private_key is not an RSA key")
        }
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(Data(pkcs1) as CFData, attributes as CFDictionary, &error) else {
            let detail = error?.takeRetainedValue().localizedDescription ?? "unknown error"
            throw AuthError.invalidKeyFile("private_key rejected: \(detail)")
        }
        return key
    }

    /// PKCS#8 PrivateKeyInfo ::= SEQUENCE { INTEGER version,
    /// SEQUENCE algorithm, OCTET STRING privateKey } -- the OCTET STRING
    /// holds the PKCS#1 key. PKCS#1 RSAPrivateKey ::= SEQUENCE { INTEGER
    /// version, INTEGER modulus, ... }, so the second child's tag tells
    /// the two apart.
    static func pkcs1RSAKey(fromDER bytes: [UInt8]) -> [UInt8]? {
        guard let outer = readTLV(bytes, at: 0), outer.tag == 0x30 else { return nil }
        guard let version = readTLV(bytes, at: outer.content.lowerBound), version.tag == 0x02 else { return nil }
        guard let second = readTLV(bytes, at: version.content.upperBound) else { return nil }
        switch second.tag {
        case 0x02:
            return Array(bytes[0..<outer.content.upperBound])
        case 0x30:
            guard let octets = readTLV(bytes, at: second.content.upperBound), octets.tag == 0x04 else { return nil }
            return Array(bytes[octets.content])
        default:
            return nil
        }
    }

    /// Reads one DER tag-length-value at `index`; nil if it would run
    /// past the end of `bytes`.
    static func readTLV(_ bytes: [UInt8], at index: Int) -> (tag: UInt8, content: Range<Int>)? {
        guard index + 1 < bytes.count else { return nil }
        let tag = bytes[index]
        var cursor = index + 1
        let first = bytes[cursor]
        cursor += 1
        var length = 0
        if first < 0x80 {
            length = Int(first)
        } else {
            let count = Int(first & 0x7F)
            guard count > 0, count <= 4, cursor + count <= bytes.count else { return nil }
            for _ in 0..<count {
                length = (length << 8) | Int(bytes[cursor])
                cursor += 1
            }
        }
        guard cursor + length <= bytes.count else { return nil }
        return (tag, cursor..<(cursor + length))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
