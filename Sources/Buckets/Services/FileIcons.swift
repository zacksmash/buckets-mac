import QuickLookThumbnailing
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Real Finder icons for file types, cached per extension.
enum FileIcons {
    private static var cache: [String: NSImage] = [:]
    private static let lock = NSLock()

    static func icon(for item: BrowserItem) -> NSImage {
        icon(forName: item.name, isFolder: item.isFolder)
    }

    static func icon(forName name: String, isFolder: Bool) -> NSImage {
        let ext = (name as NSString).pathExtension.lowercased()
        let cacheKey = isFolder ? "/folder" : ext
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[cacheKey] { return cached }

        let type: UTType
        if isFolder {
            type = .folder
        } else if !ext.isEmpty, let resolved = UTType(filenameExtension: ext) {
            type = resolved
        } else {
            type = .data
        }
        let image = NSWorkspace.shared.icon(for: type)
        cache[cacheKey] = image
        return image
    }
}

/// A generated preview, plus the original pixel size for images.
final class Thumbnail {
    let image: NSImage
    let pixelSize: CGSize?

    init(image: NSImage, pixelSize: CGSize?) {
        self.image = image
        self.pixelSize = pixelSize
    }

    /// Rough memory cost for NSCache.
    var cost: Int { Int(image.size.width * image.size.height * 4) }

    static let maxPixelSize: CGFloat = 512

    static var temporaryRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Buckets/Thumbnails", isDirectory: true)
    }

    static func generate(from file: URL, isImage: Bool) async throws -> Thumbnail {
        let request = QLThumbnailGenerator.Request(
            fileAt: file,
            size: CGSize(width: maxPixelSize, height: maxPixelSize),
            scale: 1,
            representationTypes: .thumbnail
        )
        let representation = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
        var pixelSize: CGSize?
        if isImage, let source = CGImageSourceCreateWithURL(file as CFURL, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? Int,
           let height = properties[kCGImagePropertyPixelHeight] as? Int {
            pixelSize = CGSize(width: width, height: height)
        }
        return Thumbnail(image: representation.nsImage, pixelSize: pixelSize)
    }
}
