import CoreTransferable
import UniformTypeIdentifiers

/// A file dragged out of the browser. The Finder gets a file promise, and the object is
/// only downloaded once it's dropped.
struct DraggedObject: Transferable {
    let key: String
    let name: String
    let client: S3Client

    static var temporaryRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Buckets/Drag", isDirectory: true)
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .data) { object in
            let folder = temporaryRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
            guard let destination = LocalFiles.safeURL(for: object.name, in: folder) else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
            try await object.client.download(object.key, to: destination) { _, _ in }
            return SentTransferredFile(destination, allowAccessingOriginalFile: false)
        }
        .suggestedFileName { $0.name }
    }
}
