import Foundation
import CryptoKit

/// AWS Signature Version 4 request signing, as used by S3 and Cloudflare R2.
struct SigV4Signer: Sendable {
    let accessKeyID: String
    let secretAccessKey: String
    let region: String
    let service = "s3"

    static let emptyPayloadHash = Data().sha256Hex
    static let unsignedPayload = "UNSIGNED-PAYLOAD"

    private static let amzDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter
    }()

    /// Signs `request` in place. `canonicalURI` and `canonicalQuery` must be
    /// exactly the percent-encoded path and query used to build the URL.
    func sign(
        _ request: inout URLRequest,
        canonicalURI: String,
        canonicalQuery: String,
        payloadHash: String,
        date: Date = Date()
    ) {
        let amzDate = Self.amzDateFormatter.string(from: date)
        let dateStamp = String(amzDate.prefix(8))
        request.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")

        guard let url = request.url, let host = url.host else { return }
        // IPv6 literals keep their brackets in the Host header.
        var hostValue = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        if let port = url.port, !(url.scheme == "https" && port == 443), !(url.scheme == "http" && port == 80) {
            hostValue += ":\(port)"
        }

        var headers: [String: String] = ["host": hostValue]
        for (name, value) in request.allHTTPHeaderFields ?? [:] {
            let lowered = name.lowercased()
            if lowered.hasPrefix("x-amz-") || lowered == "content-type" || lowered == "content-md5" {
                headers[lowered] = value.trimmingCharacters(in: .whitespaces)
            }
        }

        let sortedNames = headers.keys.sorted()
        let canonicalHeaders = sortedNames.map { "\($0):\(headers[$0] ?? "")\n" }.joined()
        let signedHeaders = sortedNames.joined(separator: ";")

        let canonicalRequest = [
            request.httpMethod ?? "GET",
            canonicalURI,
            canonicalQuery,
            canonicalHeaders,
            signedHeaders,
            payloadHash,
        ].joined(separator: "\n")

        let scope = "\(dateStamp)/\(region)/\(service)/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            scope,
            Data(canonicalRequest.utf8).sha256Hex,
        ].joined(separator: "\n")

        let dateKey = hmac(key: Data("AWS4\(secretAccessKey)".utf8), message: dateStamp)
        let regionKey = hmac(key: dateKey, message: region)
        let serviceKey = hmac(key: regionKey, message: service)
        let signingKey = hmac(key: serviceKey, message: "aws4_request")
        let signature = hmac(key: signingKey, message: stringToSign).hexString

        request.setValue(
            "AWS4-HMAC-SHA256 Credential=\(accessKeyID)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)",
            forHTTPHeaderField: "Authorization"
        )
    }

    private func hmac(key: Data, message: String) -> Data {
        let code = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key))
        return Data(code)
    }

    /// RFC 3986 encoding as required by SigV4 (unreserved characters only).
    static func uriEncode(_ string: String, encodeSlash: Bool) -> String {
        var allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
        if !encodeSlash { allowed.insert(charactersIn: "/") }
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }
}
