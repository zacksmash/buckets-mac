import SwiftUI
import AppKit

/// Renders `AppIconView` into a macOS `.iconset` folder (consumed by `iconutil`).
@MainActor
enum IconRenderer {
    private static let variants: [(name: String, pixels: CGFloat)] = [
        ("icon_16x16", 16), ("icon_16x16@2x", 32),
        ("icon_32x32", 32), ("icon_32x32@2x", 64),
        ("icon_128x128", 128), ("icon_128x128@2x", 256),
        ("icon_256x256", 256), ("icon_256x256@2x", 512),
        ("icon_512x512", 512), ("icon_512x512@2x", 1024),
    ]

    static func renderIconSet(to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for variant in variants {
            let renderer = ImageRenderer(content: AppIconCanvas())
            renderer.scale = variant.pixels / 1024
            renderer.isOpaque = false
            guard let cgImage = renderer.cgImage else {
                print("Failed to render \(variant.name)")
                continue
            }
            let rep = NSBitmapImageRep(cgImage: cgImage)
            guard let png = rep.representation(using: .png, properties: [:]) else { continue }
            let url = directory.appendingPathComponent("\(variant.name).png")
            try? png.write(to: url)
        }
        print("Rendered icon set to \(directory.path)")
    }
}

/// The 1024×1024 macOS icon canvas: an 824pt body centred with room for its shadow.
struct AppIconCanvas: View {
    var body: some View {
        AppIconView(size: 824)
            .frame(width: 1024, height: 1024)
    }
}
