import Foundation

/// End-to-end check of every S3 operation the app uses, against a real endpoint.
///
///     S3_ENDPOINT=http://127.0.0.1:9000 S3_REGION=us-east-1 S3_BUCKET=test \
///     S3_ACCESS_KEY=… S3_SECRET_KEY=… Buckets --selftest
///
/// Set `S3_PROVIDER=r2` and `S3_ACCOUNT_ID` to test Cloudflare R2 instead.
/// Everything is written under a unique `buckets-selftest-…/` prefix and removed afterwards.
enum SelfTest {
    private static var failures = 0

    static func run() async -> Int32 {
        let env = ProcessInfo.processInfo.environment
        var connection = Connection()
        connection.name = "Self Test"
        if env["S3_PROVIDER"]?.lowercased() == "r2" {
            connection.provider = .cloudflareR2
            connection.accountID = env["S3_ACCOUNT_ID"] ?? ""
        } else {
            connection.provider = .s3Compatible
            connection.customEndpoint = env["S3_ENDPOINT"] ?? ""
            connection.region = env["S3_REGION"] ?? "us-east-1"
        }
        connection.bucket = env["S3_BUCKET"] ?? ""
        connection.accessKeyID = env["S3_ACCESS_KEY"] ?? ""

        await step("presigned URL matches the AWS documented example") {
            // https://docs.aws.amazon.com/AmazonS3/latest/API/sigv4-query-string-auth.html
            let signer = SigV4Signer(
                accessKeyID: "AKIAIOSFODNN7EXAMPLE",
                secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
                region: "us-east-1"
            )
            let query = signer.presignedQuery(
                url: URL(string: "https://examplebucket.s3.amazonaws.com/test.txt")!,
                canonicalURI: "/test.txt",
                expires: 86400,
                date: Date(timeIntervalSince1970: 1_369_353_600)
            )
            let expected = "aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404"
            try expect(query?.hasSuffix("X-Amz-Signature=" + expected) == true, "got \(query ?? "nil")")
        }

        let client: S3Client
        do {
            client = try S3Client(connection: connection, secret: env["S3_SECRET_KEY"] ?? "")
        } catch {
            print("✗ client: \(error.localizedDescription)")
            return 2
        }
        print("Testing \(connection.endpointURL?.absoluteString ?? "?") bucket \(connection.bucket)")

        let root = "buckets-selftest-\(UUID().uuidString.prefix(8))/"
        let oddKey = root + "docs/Ünïcode & spaces + plus (1).txt"
        let text = "Hello from Buckets ✓\nLine two.\n"
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("buckets-selftest", isDirectory: true)
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)

        await step("test connection") { _ = try await client.testConnection() }
        await step("create folder") { try await client.createFolder(root + "empty folder") }
        await step("put object with unusual key") {
            try await client.putObject(oddKey, data: Data(text.utf8), contentType: "text/plain; charset=utf-8")
        }
        await step("list with delimiter shows folders") {
            let listing = try await client.list(prefix: root)
            try expect(Set(listing.prefixes) == [root + "docs/", root + "empty folder/"], "prefixes \(listing.prefixes)")
        }
        await step("get object round-trips") {
            let data = try await client.getObjectData(oddKey)
            try expect(String(data: data, encoding: .utf8) == text, "content mismatch")
        }
        await step("presigned URL downloads without credentials") {
            let url = try client.presignedURL(for: oddKey, expiresIn: 60)
            let (data, response) = try await URLSession.shared.data(from: url)
            try expect((response as? HTTPURLResponse)?.statusCode == 200, "status \((response as? HTTPURLResponse)?.statusCode ?? 0)")
            try expect(String(data: data, encoding: .utf8) == text, "content mismatch")
        }
        await step("ranged get") {
            let data = try await client.getObjectData(oddKey, maxBytes: 5)
            try expect(data == Data("Hello".utf8), "got \(data.count) bytes")
        }
        await step("head object") {
            let meta = try await client.headObject(oddKey)
            try expect(meta.contentLength == Int64(Data(text.utf8).count), "length \(meta.contentLength)")
            try expect(meta.contentType?.hasPrefix("text/plain") == true, "type \(meta.contentType ?? "nil")")
        }
        await step("copy (rename)") {
            try await client.copyObject(from: oddKey, to: root + "renamed copy.txt")
            let data = try await client.getObjectData(root + "renamed copy.txt")
            try expect(String(data: data, encoding: .utf8) == text, "copy content mismatch")
        }

        let small = temp.appendingPathComponent("small.bin")
        let large = temp.appendingPathComponent("large.bin")
        await step("upload file (single PUT, 6 MB)") {
            try makeFile(small, megabytes: 6)
            try await client.uploadFile(small, to: root + "uploads/small.bin", contentType: "application/octet-stream") { _, _ in }
            let meta = try await client.headObject(root + "uploads/small.bin")
            try expect(meta.contentLength == 6 * 1024 * 1024, "size \(meta.contentLength)")
        }
        await step("upload file (multipart, 120 MB)") {
            try makeFile(large, megabytes: 120)
            let progress = ProgressRecorder()
            try await client.uploadFile(large, to: root + "uploads/large.bin", contentType: "application/octet-stream") { done, total in
                progress.record(done, total)
            }
            let meta = try await client.headObject(root + "uploads/large.bin")
            try expect(meta.contentLength == 120 * 1024 * 1024, "size \(meta.contentLength)")
            try expect(progress.maxDone == 120 * 1024 * 1024, "progress reached \(progress.maxDone)")
        }
        await step("download with progress") {
            let destination = temp.appendingPathComponent("downloaded.bin")
            try await client.download(root + "uploads/small.bin", to: destination) { _, _ in }
            let original = try Data(contentsOf: small)
            let downloaded = try Data(contentsOf: destination)
            try expect(original == downloaded, "downloaded bytes differ")
        }
        await step("recursive list") {
            let all = try await client.list(prefix: root, delimiter: nil)
            try expect(all.objects.count == 5, "found \(all.objects.count) objects: \(all.objects.map(\.key))")
        }
        await step("batch delete everything") {
            let all = try await client.list(prefix: root, delimiter: nil)
            try await client.deleteObjects(all.objects.map(\.key))
            let after = try await client.list(prefix: root, delimiter: nil)
            try expect(after.objects.isEmpty, "\(after.objects.count) objects remain")
        }
        await step("bad secret is rejected") {
            let bad = try S3Client(connection: connection, secret: "definitely-wrong")
            do {
                _ = try await bad.testConnection()
                throw SelfTestError("request with a wrong secret succeeded")
            } catch let error as S3Error {
                print("    (message: \(error.localizedDescription))")
            }
        }

        try? FileManager.default.removeItem(at: temp)
        print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) failed.")
        return failures == 0 ? 0 : 1
    }

    private static func step(_ name: String, _ body: () async throws -> Void) async {
        let start = Date()
        do {
            try await body()
            print(String(format: "✓ %@ (%.2fs)", name, Date().timeIntervalSince(start)))
        } catch {
            failures += 1
            print("✗ \(name): \(error.localizedDescription) [\(error)]")
        }
    }

    private static func expect(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        if !condition { throw SelfTestError(message()) }
    }

    private static func makeFile(_ url: URL, megabytes: Int) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var chunk = Data(count: 1024 * 1024)
        for index in 0 ..< megabytes {
            chunk.withUnsafeMutableBytes { buffer in
                for offset in stride(from: 0, to: buffer.count, by: 4096) {
                    buffer[offset] = UInt8(truncatingIfNeeded: index &+ offset)
                }
            }
            try handle.write(contentsOf: chunk)
        }
    }
}

private struct SelfTestError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var maxDone: Int64 = 0
    func record(_ done: Int64, _ total: Int64) {
        lock.lock()
        maxDone = max(maxDone, done)
        lock.unlock()
    }
}
