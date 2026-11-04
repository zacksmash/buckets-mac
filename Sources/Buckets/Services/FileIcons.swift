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

enum Thumbnailer {
    /// Downsamples image data efficiently with ImageIO.
    static func thumbnail(from data: Data, maxPixelSize: CGFloat) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    static func pixelSize(of data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return CGSize(width: width, height: height)
    }
}
