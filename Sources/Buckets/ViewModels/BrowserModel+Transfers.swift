import SwiftUI
import AppKit

extension BrowserModel {
    // MARK: - Uploads

    func upload(_ urls: [URL], into destination: String? = nil) {
        guard let client else { return }
        let target = destination ?? prefix
        for url in urls {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory {
                uploadDirectory(url, into: target, client: client)
            } else {
                uploadFile(url, into: target, client: client)
            }
        }
    }

    private func uploadFile(_ url: URL, into target: String, client: S3Client) {
        let name = url.lastPathComponent
        let key = target + name
        let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let contentType = MIME.type(forFileName: name)

        transfers.enqueue(
            name: name,
            direction: .upload,
            destination: folderDescription(target),
            totalBytes: size,
            operation: { progress in
                try await client.uploadFile(url, to: key, contentType: contentType, progress: progress)
            },
            onFinish: { [weak self] success in
                guard success, let self, target == self.prefix else { return }
                self.scheduleReload()
            }
        )
    }

    private func uploadDirectory(_ directory: URL, into target: String, client: S3Client) {
        let folderName = directory.lastPathComponent
        let root = target + folderName + "/"
        let baseComponents = directory.standardizedFileURL.pathComponents.count

        transfers.enqueue(
            name: folderName,
            isFolder: true,
            direction: .upload,
            destination: folderDescription(target),
            totalBytes: 0,
            operation: { progress in
                var files: [(url: URL, key: String, size: Int64)] = []
                let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
                if let enumerator = FileManager.default.enumerator(
                    at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
                ) {
                    while let fileURL = enumerator.nextObject() as? URL {
                        let values = try? fileURL.resourceValues(forKeys: Set(keys))
                        guard values?.isRegularFile == true else { continue }
                        let relative = fileURL.standardizedFileURL.pathComponents.dropFirst(baseComponents).joined(separator: "/")
                        files.append((fileURL, root + relative, Int64(values?.fileSize ?? 0)))
                    }
                }
                var batch = BatchProgress(total: files.reduce(Int64(0)) { $0 + $1.size }, report: progress)
                try await client.createFolder(root)
                for file in files {
                    try await batch.run(size: file.size) { fileProgress in
                        try await client.uploadFile(
                            file.url, to: file.key, contentType: MIME.type(forFileName: file.url.lastPathComponent)
                        ) { sent, _ in fileProgress(sent) }
                    }
                }
            },
            onFinish: { [weak self] _ in
                guard let self, target == self.prefix else { return }
                self.scheduleReload()
            }
        )
    }

    // MARK: - Downloads

    /// What dragging `item` out to the Finder carries. Folders can't be dragged out yet.
    func dragItemProvider(for item: BrowserItem) -> NSItemProvider? {
        guard !item.isFolder, let client else { return nil }
        let provider = NSItemProvider()
        provider.register(DraggedObject(key: item.key, name: item.name, client: client))
        provider.suggestedName = item.name
        return provider
    }

    func downloadSelection() {
        download(selection)
    }

    func download(_ ids: Set<BrowserItem.ID>) {
        guard let client else { return }
        for item in items(for: ids) {
            let destination = LocalFiles.uniqueURL(in: LocalFiles.downloadsFolder, name: item.name, reserved: reservedPaths)
            reservedPaths.insert(destination.path)
            if item.isFolder {
                downloadFolder(item, to: destination, client: client)
            } else {
                transfers.enqueue(
                    name: destination.lastPathComponent,
                    direction: .download,
                    destination: "Downloads",
                    totalBytes: item.size,
                    localURL: destination,
                    operation: { progress in
                        try await client.download(item.key, to: destination, progress: progress)
                    },
                    onFinish: { [weak self] success in
                        self?.reservedPaths.remove(destination.path)
                        if success { Self.bounceDownloads(destination) }
                    }
                )
            }
        }
    }

    private func downloadFolder(_ item: BrowserItem, to destination: URL, client: S3Client) {
        transfers.enqueue(
            name: destination.lastPathComponent,
            isFolder: true,
            direction: .download,
            destination: "Downloads",
            totalBytes: 0,
            localURL: destination,
            operation: { progress in
                // A first pass sizes the folder so progress is accurate; neither pass holds the whole listing.
                var total: Int64 = 0
                try await client.forEachFilePage(under: item.key) { files in
                    total += files.reduce(Int64(0)) { $0 + $1.size }
                }
                var batch = BatchProgress(total: total, report: progress)
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                var skipped: [String] = []
                try await client.forEachFilePage(under: item.key) { files in
                    for object in files {
                        let relative = String(object.key.dropFirst(item.key.count))
                        guard let target = LocalFiles.safeURL(for: relative, in: destination) else {
                            skipped.append(object.key)
                            batch.skip(object.size)
                            continue
                        }
                        // Replacing is safe here: the target is checked to sit inside our own new folder.
                        try await batch.run(size: object.size) { fileProgress in
                            try await client.download(object.key, to: target, replaceExisting: true) { received, _ in
                                fileProgress(received)
                            }
                        }
                    }
                }
                if !skipped.isEmpty {
                    throw DownloadError.unsafeKeys(skipped)
                }
            },
            onFinish: { [weak self] success in
                self?.reservedPaths.remove(destination.path)
                if success { Self.bounceDownloads(destination) }
            }
        )
    }

    enum DownloadError: LocalizedError {
        case unsafeKeys([String])

        var errorDescription: String? {
            switch self {
            case let .unsafeKeys(keys):
                let sample = keys.prefix(3).map { "“\($0)”" }.joined(separator: ", ")
                return keys.count == 1
                    ? "Skipped \(sample) because its name isn't safe to save on this Mac."
                    : "Skipped \(keys.count) files whose names aren't safe to save on this Mac, including \(sample)."
            }
        }
    }

    /// Makes the Downloads stack in the Dock bounce, like Safari.
    private static func bounceDownloads(_ url: URL) {
        DistributedNotificationCenter.default().post(
            name: Notification.Name("com.apple.DownloadFileFinished"),
            object: url.path
        )
    }
}
