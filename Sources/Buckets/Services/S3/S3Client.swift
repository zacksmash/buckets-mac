import Foundation
import CryptoKit

struct S3Object: Sendable {
    let key: String
    let size: Int64
    let lastModified: Date?
    let etag: String?
}

struct S3ListPage: Sendable {
    let objects: [S3Object]
    let prefixes: [String]
    let isTruncated: Bool
    let nextContinuationToken: String?
}

struct S3ObjectMetadata: Sendable {
    let contentType: String?
    let contentLength: Int64
    let lastModified: Date?
    let etag: String?
    let cacheControl: String?
    let userMetadata: [(key: String, value: String)]
}

enum S3Error: LocalizedError {
    case invalidEndpoint
    case missingCredentials
    case notConfigured
    case invalidResponse
    case service(code: String, message: String, status: Int)
    case http(status: Int)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            "The endpoint isn't valid. Check the account ID or endpoint URL in this connection's settings."
        case .missingCredentials:
            "This connection is missing its access key ID or secret access key."
        case .notConfigured:
            "The connection isn't ready yet."
        case .invalidResponse:
            "The server sent a response that couldn't be read."
        case let .service(code, message, status):
            Self.friendlyMessage(code: code, message: message, status: status)
        case let .http(status):
            Self.friendlyMessage(code: "", message: "", status: status)
        }
    }

    private static func friendlyMessage(code: String, message: String, status: Int) -> String {
        switch code {
        case "SignatureDoesNotMatch":
            return "The secret access key doesn't match this access key ID."
        case "InvalidAccessKeyId":
            return "The access key ID wasn't recognized."
        case "NoSuchBucket":
            return "That bucket doesn't exist at this endpoint."
        case "AccessDenied":
            return "Access denied. These credentials don't have permission to do that."
        case "RequestTimeTooSkewed":
            return "Your Mac's clock is too far out of sync with the server."
        case "NoSuchKey":
            return "The file no longer exists."
        case "EntityTooLarge":
            return "The file is too large to upload in a single request."
        default:
            if !message.isEmpty { return message }
            switch status {
            case 401, 403: return "Access denied (\(status)). Check your credentials and the token's bucket permissions."
            case 404: return "Not found (404). Check the bucket name and endpoint."
            default: return "The server returned an error (\(status) \(HTTPURLResponse.localizedString(forStatusCode: status)))."
            }
        }
    }

    static func from(data: Data, status: Int) -> S3Error {
        if let root = XMLTree.parse(data), root.name == "Error" {
            return .service(code: root.value("Code") ?? "", message: root.value("Message") ?? "", status: status)
        }
        return .http(status: status)
    }
}

/// Signals that should be treated as user cancellation rather than failure.
func isCancellation(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    if let urlError = error as? URLError, urlError.code == .cancelled { return true }
    return false
}

/// Box shared between a URLSession task and its cancellation handler.
private final class TaskBox: @unchecked Sendable {
    var task: URLSessionTask?
    var observation: NSKeyValueObservation?
}

/// A dependency-free S3 client covering everything the browser needs.
/// Uses path-style addressing, which R2 and most S3-compatible services support.
final class S3Client: @unchecked Sendable {
    let endpoint: URL
    let bucket: String
    private let signer: SigV4Signer
    private let session: URLSession

    static let multipartThreshold: Int64 = 100 * 1024 * 1024
    static let minimumPartSize: Int64 = 16 * 1024 * 1024

    init(connection: Connection, secret: String) throws {
        guard let endpoint = connection.endpointURL else { throw S3Error.invalidEndpoint }
        let accessKey = connection.accessKeyID.trimmed
        let secretKey = secret.trimmed
        guard !accessKey.isEmpty, !secretKey.isEmpty else { throw S3Error.missingCredentials }
        guard !connection.bucket.trimmed.isEmpty else { throw S3Error.invalidEndpoint }

        self.endpoint = endpoint
        self.bucket = connection.bucket.trimmed
        self.signer = SigV4Signer(accessKeyID: accessKey, secretAccessKey: secretKey, region: connection.signingRegion)

        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60 * 60 * 24
        configuration.httpMaximumConnectionsPerHost = 8
        configuration.waitsForConnectivity = false
        self.session = URLSession(configuration: configuration)
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    // MARK: - Request construction

    private func makeRequest(
        method: String,
        key: String? = nil,
        query: [(String, String)] = [],
        headers: [String: String] = [:],
        payloadHash: String
    ) throws -> URLRequest {
        var basePath = endpoint.path
        while basePath.hasSuffix("/") { basePath.removeLast() }
        var canonicalURI = SigV4Signer.uriEncode(basePath, encodeSlash: false)
        canonicalURI += "/" + SigV4Signer.uriEncode(bucket, encodeSlash: true)
        if let key {
            canonicalURI += "/" + SigV4Signer.uriEncode(key, encodeSlash: false)
        }

        let encodedQuery: [(String, String)] = query.map { pair in
            (SigV4Signer.uriEncode(pair.0, encodeSlash: true), SigV4Signer.uriEncode(pair.1, encodeSlash: true))
        }
        let sortedQuery = encodedQuery.sorted { (a: (String, String), b: (String, String)) -> Bool in
            a.0 == b.0 ? a.1 < b.1 : a.0 < b.0
        }
        let canonicalQuery = sortedQuery.map { "\($0.0)=\($0.1)" }.joined(separator: "&")

        var components = URLComponents()
        components.scheme = endpoint.scheme ?? "https"
        components.host = endpoint.host
        components.port = endpoint.port
        components.percentEncodedPath = canonicalURI
        if !canonicalQuery.isEmpty { components.percentEncodedQuery = canonicalQuery }
        guard let url = components.url else { throw S3Error.invalidEndpoint }

        var request = URLRequest(url: url)
        request.httpMethod = method
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        signer.sign(&request, canonicalURI: canonicalURI, canonicalQuery: canonicalQuery, payloadHash: payloadHash)
        return request
    }

    @discardableResult
    private func perform(_ request: URLRequest, body: Data? = nil) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        if let body {
            (data, response) = try await session.upload(for: request, from: body)
        } else {
            (data, response) = try await session.data(for: request)
        }
        guard let http = response as? HTTPURLResponse else { throw S3Error.invalidResponse }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw S3Error.from(data: data, status: http.statusCode)
        }
        return (data, http)
    }

    // MARK: - Listing

    func listPage(
        prefix: String,
        delimiter: String? = "/",
        continuationToken: String? = nil,
        maxKeys: Int = 1000
    ) async throws -> S3ListPage {
        var query: [(String, String)] = [("list-type", "2"), ("max-keys", String(maxKeys))]
        if !prefix.isEmpty { query.append(("prefix", prefix)) }
        if let delimiter { query.append(("delimiter", delimiter)) }
        if let continuationToken { query.append(("continuation-token", continuationToken)) }

        let request = try makeRequest(method: "GET", query: query, payloadHash: SigV4Signer.emptyPayloadHash)
        let (data, _) = try await perform(request)
        guard let root = XMLTree.parse(data), root.name == "ListBucketResult" else {
            throw S3Error.invalidResponse
        }

        let objects: [S3Object] = root.all("Contents").compactMap { node in
            guard let key = node.value("Key") else { return nil }
            return S3Object(
                key: key,
                size: Int64(node.value("Size") ?? "") ?? 0,
                lastModified: node.value("LastModified").flatMap(S3Date.parseISO),
                etag: node.value("ETag")?.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            )
        }
        let prefixes = root.all("CommonPrefixes").compactMap { $0.value("Prefix") }

        return S3ListPage(
            objects: objects,
            prefixes: prefixes,
            isTruncated: root.value("IsTruncated") == "true",
            nextContinuationToken: root.value("NextContinuationToken")
        )
    }

    /// Lists everything under `prefix`, following continuation tokens.
    func list(prefix: String, delimiter: String? = "/") async throws -> (objects: [S3Object], prefixes: [String]) {
        var objects: [S3Object] = []
        var prefixes: [String] = []
        var token: String?
        repeat {
            try Task.checkCancellation()
            let page = try await listPage(prefix: prefix, delimiter: delimiter, continuationToken: token)
            objects += page.objects
            prefixes += page.prefixes
            token = page.isTruncated ? page.nextContinuationToken : nil
        } while token != nil
        return (objects, prefixes)
    }

    /// Lightweight check used by "Test Connection". Returns the number of top-level entries seen.
    func testConnection() async throws -> (count: Int, hasMore: Bool) {
        let page = try await listPage(prefix: "", delimiter: "/", maxKeys: 100)
        return (page.objects.count + page.prefixes.count, page.isTruncated)
    }

    // MARK: - Objects

    func headObject(_ key: String) async throws -> S3ObjectMetadata {
        let request = try makeRequest(method: "HEAD", key: key, payloadHash: SigV4Signer.emptyPayloadHash)
        let (_, http) = try await perform(request)
        var userMetadata: [(key: String, value: String)] = []
        for (name, value) in http.allHeaderFields {
            guard let name = name as? String else { continue }
            let lowered = name.lowercased()
            if lowered.hasPrefix("x-amz-meta-") {
                userMetadata.append((String(lowered.dropFirst("x-amz-meta-".count)), "\(value)"))
            }
        }
        return S3ObjectMetadata(
            contentType: http.value(forHTTPHeaderField: "Content-Type"),
            contentLength: Int64(http.value(forHTTPHeaderField: "Content-Length") ?? "") ?? 0,
            lastModified: http.value(forHTTPHeaderField: "Last-Modified").flatMap(S3Date.parseHTTP),
            etag: http.value(forHTTPHeaderField: "ETag")?.trimmingCharacters(in: CharacterSet(charactersIn: "\"")),
            cacheControl: http.value(forHTTPHeaderField: "Cache-Control"),
            userMetadata: userMetadata.sorted { $0.key < $1.key }
        )
    }

    func getObjectData(_ key: String, maxBytes: Int? = nil) async throws -> Data {
        var headers: [String: String] = [:]
        if let maxBytes, maxBytes > 0 { headers["Range"] = "bytes=0-\(maxBytes - 1)" }
        let request = try makeRequest(method: "GET", key: key, headers: headers, payloadHash: SigV4Signer.emptyPayloadHash)
        return try await perform(request).0
    }

    func putObject(_ key: String, data: Data, contentType: String? = nil) async throws {
        var headers: [String: String] = [:]
        if let contentType { headers["Content-Type"] = contentType }
        let request = try makeRequest(method: "PUT", key: key, headers: headers, payloadHash: data.sha256Hex)
        try await perform(request, body: data)
    }

    func createFolder(_ key: String) async throws {
        let folderKey = key.hasSuffix("/") ? key : key + "/"
        try await putObject(folderKey, data: Data())
    }

    func deleteObject(_ key: String) async throws {
        let request = try makeRequest(method: "DELETE", key: key, payloadHash: SigV4Signer.emptyPayloadHash)
        try await perform(request)
    }

    /// Batch delete, 1,000 keys per request.
    func deleteObjects(_ keys: [String]) async throws {
        for chunk in keys.chunked(into: 1000) where !chunk.isEmpty {
            try Task.checkCancellation()
            if chunk.count == 1 {
                try await deleteObject(chunk[0])
                continue
            }
            var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Delete><Quiet>true</Quiet>"
            for key in chunk { xml += "<Object><Key>\(key.xmlEscaped)</Key></Object>" }
            xml += "</Delete>"
            let body = Data(xml.utf8)
            let md5 = Data(Insecure.MD5.hash(data: body)).base64EncodedString()
            let request = try makeRequest(
                method: "POST",
                query: [("delete", "")],
                headers: ["Content-MD5": md5, "Content-Type": "application/xml"],
                payloadHash: body.sha256Hex
            )
            let (data, _) = try await perform(request, body: body)
            if let root = XMLTree.parse(data), let failure = root.all("Error").first {
                let key = failure.value("Key") ?? ""
                let message = failure.value("Message") ?? "Unknown error"
                throw S3Error.service(code: failure.value("Code") ?? "", message: "Couldn't delete “\(key)”: \(message)", status: 200)
            }
        }
    }

    func copyObject(from source: String, to destination: String) async throws {
        let copySource = "/" + SigV4Signer.uriEncode(bucket, encodeSlash: true) + "/" + SigV4Signer.uriEncode(source, encodeSlash: false)
        let request = try makeRequest(
            method: "PUT",
            key: destination,
            headers: ["x-amz-copy-source": copySource],
            payloadHash: SigV4Signer.emptyPayloadHash
        )
        let (data, http) = try await perform(request, body: Data())
        // S3 may report a copy failure with a 200 status and an <Error> body.
        if let root = XMLTree.parse(data), root.name == "Error" {
            throw S3Error.service(code: root.value("Code") ?? "", message: root.value("Message") ?? "", status: http.statusCode)
        }
    }

    // MARK: - Transfers

    func download(
        _ key: String,
        to destination: URL,
        replaceExisting: Bool = false,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {
        let request = try makeRequest(method: "GET", key: key, payloadHash: SigV4Signer.emptyPayloadHash)
        let box = TaskBox()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let task = session.downloadTask(with: request) { location, response, error in
                    box.observation?.invalidate()
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    guard let http = response as? HTTPURLResponse, let location else {
                        continuation.resume(throwing: S3Error.invalidResponse)
                        return
                    }
                    guard (200 ..< 300).contains(http.statusCode) else {
                        let body = (try? Data(contentsOf: location)) ?? Data()
                        continuation.resume(throwing: S3Error.from(data: body, status: http.statusCode))
                        return
                    }
                    do {
                        let fileManager = FileManager.default
                        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                        if replaceExisting, fileManager.fileExists(atPath: destination.path) {
                            try fileManager.removeItem(at: destination)
                        }
                        try fileManager.moveItem(at: location, to: destination)
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                box.observation = task.observe(\.countOfBytesReceived, options: [.new]) { task, _ in
                    progress(task.countOfBytesReceived, task.countOfBytesExpectedToReceive)
                }
                box.task = task
                task.resume()
                if Task.isCancelled { task.cancel() }
            }
        } onCancel: {
            box.task?.cancel()
        }
    }

    /// Uploads a local file, switching to multipart for large files.
    func uploadFile(
        _ fileURL: URL,
        to key: String,
        contentType: String,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0

        if size < Self.multipartThreshold {
            let request = try makeRequest(
                method: "PUT",
                key: key,
                headers: ["Content-Type": contentType],
                payloadHash: SigV4Signer.unsignedPayload
            )
            try await runUpload(request, fileURL: fileURL) { sent in progress(sent, size) }
            progress(size, size)
        } else {
            try await multipartUpload(fileURL, key: key, size: size, contentType: contentType, progress: progress)
        }
    }

    private func multipartUpload(
        _ fileURL: URL,
        key: String,
        size: Int64,
        contentType: String,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {
        let createRequest = try makeRequest(
            method: "POST",
            key: key,
            query: [("uploads", "")],
            headers: ["Content-Type": contentType],
            payloadHash: SigV4Signer.emptyPayloadHash
        )
        let (createData, _) = try await perform(createRequest, body: Data())
        guard let uploadID = XMLTree.parse(createData)?.value("UploadId") else { throw S3Error.invalidResponse }

        do {
            // R2 requires every part except the last to be the same size.
            let partSize = max(Self.minimumPartSize, Int64((Double(size) / 9_000).rounded(.up)))
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }

            var parts: [(number: Int, etag: String)] = []
            var offset: Int64 = 0
            var partNumber = 1

            while offset < size {
                try Task.checkCancellation()
                let length = Int(min(partSize, size - offset))
                try handle.seek(toOffset: UInt64(offset))
                guard let chunk = try handle.read(upToCount: length), !chunk.isEmpty else { break }

                let request = try makeRequest(
                    method: "PUT",
                    key: key,
                    query: [("partNumber", String(partNumber)), ("uploadId", uploadID)],
                    payloadHash: SigV4Signer.unsignedPayload
                )
                let base = offset
                let response = try await runUpload(request, data: chunk) { sent in progress(base + sent, size) }
                guard let etag = response.value(forHTTPHeaderField: "ETag") else { throw S3Error.invalidResponse }
                parts.append((partNumber, etag))
                offset += Int64(chunk.count)
                partNumber += 1
            }

            var xml = "<CompleteMultipartUpload>"
            for part in parts {
                xml += "<Part><PartNumber>\(part.number)</PartNumber><ETag>\(part.etag.xmlEscaped)</ETag></Part>"
            }
            xml += "</CompleteMultipartUpload>"
            let body = Data(xml.utf8)
            let completeRequest = try makeRequest(
                method: "POST",
                key: key,
                query: [("uploadId", uploadID)],
                headers: ["Content-Type": "application/xml"],
                payloadHash: body.sha256Hex
            )
            let (completeData, http) = try await perform(completeRequest, body: body)
            if let root = XMLTree.parse(completeData), root.name == "Error" {
                throw S3Error.service(code: root.value("Code") ?? "", message: root.value("Message") ?? "", status: http.statusCode)
            }
            progress(size, size)
        } catch {
            if let abort = try? makeRequest(
                method: "DELETE",
                key: key,
                query: [("uploadId", uploadID)],
                payloadHash: SigV4Signer.emptyPayloadHash
            ) {
                // Detached so a cancelled transfer doesn't cancel its own abort request.
                await Task.detached { [self] in _ = try? await perform(abort) }.value
            }
            throw error
        }
    }

    @discardableResult
    private func runUpload(
        _ request: URLRequest,
        fileURL: URL? = nil,
        data: Data? = nil,
        progress: (@Sendable (Int64) -> Void)? = nil
    ) async throws -> HTTPURLResponse {
        let box = TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HTTPURLResponse, Error>) in
                let completion: @Sendable (Data?, URLResponse?, Error?) -> Void = { body, response, error in
                    box.observation?.invalidate()
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    guard let http = response as? HTTPURLResponse else {
                        continuation.resume(throwing: S3Error.invalidResponse)
                        return
                    }
                    guard (200 ..< 300).contains(http.statusCode) else {
                        continuation.resume(throwing: S3Error.from(data: body ?? Data(), status: http.statusCode))
                        return
                    }
                    continuation.resume(returning: http)
                }

                let task: URLSessionUploadTask
                if let fileURL {
                    task = session.uploadTask(with: request, fromFile: fileURL, completionHandler: completion)
                } else {
                    task = session.uploadTask(with: request, from: data ?? Data(), completionHandler: completion)
                }
                if let progress {
                    box.observation = task.observe(\.countOfBytesSent, options: [.new]) { task, _ in
                        progress(task.countOfBytesSent)
                    }
                }
                box.task = task
                task.resume()
                if Task.isCancelled { task.cancel() }
            }
        } onCancel: {
            box.task?.cancel()
        }
    }
}
