import SwiftUI
import AppKit

extension BrowserModel {
    // MARK: - Preview, Quick Look & editing

    func toggleQuickLook() {
        if quickLookURL != nil {
            quickLookURL = nil
        } else if let item = selectedItems.first, !item.isFolder {
            quickLook(item)
        }
    }

    func quickLook(_ item: BrowserItem) {
        guard !item.isFolder, let client else { return }
        let folder = Self.quickLookRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        guard let destination = LocalFiles.safeURL(for: item.name, in: folder),
              destination.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL
        else {
            errorMessage = "“\(item.name)” can't be previewed because its name isn't safe to save on this Mac."
            return
        }
        busyMessage = "Preparing preview…"
        Task {
            defer { busyMessage = nil }
            do {
                try await client.download(item.key, to: destination) { _, _ in }
                quickLookURL = destination
            } catch {
                present(error)
            }
        }
    }

    func edit(_ item: BrowserItem) {
        guard let client else { return }
        guard item.size <= 10_000_000 else {
            errorMessage = "“\(item.name)” is too large to edit here (\(Format.bytes(item.size))). Download it instead."
            return
        }
        busyMessage = "Opening “\(item.name)”…"
        Task {
            defer { busyMessage = nil }
            do {
                // Read the ETag first: if the file changes before the GET, saving fails safe with a conflict.
                let metadata = try? await client.headObject(item.key)
                let data = try await client.getObjectData(item.key)
                let encoding: String.Encoding
                let text: String
                if let utf8 = String(data: data, encoding: .utf8) {
                    text = utf8
                    encoding = .utf8
                } else if let latin = String(data: data, encoding: .isoLatin1) {
                    text = latin
                    encoding = .isoLatin1
                } else {
                    errorMessage = "“\(item.name)” doesn't look like a text file."
                    return
                }
                editingDocument = TextDocument(
                    item: item,
                    original: text,
                    encoding: encoding,
                    contentType: metadata?.contentType ?? MIME.type(forFileName: item.name)
                )
                if let document = editingDocument {
                    editETags[document.id] = metadata?.etag ?? item.etag
                }
            } catch {
                present(error)
            }
        }
    }

    func save(_ document: TextDocument, text: String) async throws {
        let client = try requireClient()
        guard let data = text.data(using: document.encoding) else {
            throw SaveError.unencodable(document.encoding.description)
        }
        do {
            let etag = try await client.putObject(
                document.item.key, data: data, contentType: document.contentType, ifMatch: editETags[document.id]
            )
            editETags[document.id] = etag
        } catch let S3Error.service(code, _, status) where status == 412 || code == "PreconditionFailed" {
            throw SaveError.changedOnServer(document.item.name)
        } catch S3Error.http(412) {
            throw SaveError.changedOnServer(document.item.name)
        }
        thumbnailCache.removeObject(forKey: document.item.key as NSString)
        reload()
    }

    enum SaveError: LocalizedError {
        case unencodable(String)
        case changedOnServer(String)

        var errorDescription: String? {
            switch self {
            case let .unencodable(encoding):
                "This text has characters that can't be saved in the file's original encoding (\(encoding)). Remove them, or download the file and edit it elsewhere."
            case let .changedOnServer(name):
                "“\(name)” changed on the server since you opened it. Close the editor and open it again to get the latest version. Your edits weren't saved."
            }
        }
    }

    func metadata(for item: BrowserItem) async throws -> S3ObjectMetadata {
        try await requireClient().headObject(item.key)
    }

    func previewData(for item: BrowserItem, maxBytes: Int? = nil) async throws -> Data {
        try await requireClient().getObjectData(item.key, maxBytes: maxBytes)
    }

    func folderStatistics(_ item: BrowserItem) async throws -> (files: Int, bytes: Int64) {
        var count = 0
        var bytes: Int64 = 0
        try await requireClient().forEachFilePage(under: item.key) { files in
            count += files.count
            bytes += files.reduce(Int64(0)) { $0 + $1.size }
        }
        return (count, bytes)
    }

    func thumbnail(for item: BrowserItem, maxPixelSize: CGFloat = 256) async -> NSImage? {
        let cacheKey = item.key as NSString
        if let cached = thumbnailCache.object(forKey: cacheKey) { return cached }
        guard item.isImage, item.size > 0, item.size <= 8_000_000, let client else { return nil }
        guard let data = try? await client.getObjectData(item.key) else { return nil }
        let image = await Task.detached(priority: .utility) {
            Thumbnailer.thumbnail(from: data, maxPixelSize: maxPixelSize)
        }.value
        if let image { thumbnailCache.setObject(image, forKey: cacheKey) }
        return image
    }
}
