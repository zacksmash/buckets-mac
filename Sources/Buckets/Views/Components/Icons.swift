import SwiftUI

/// Rounded-square "app icon" style badge for a connection.
struct ConnectionIcon: View {
    let tint: ConnectionTint
    let symbol: String
    var size: CGFloat = 40

    init(tint: ConnectionTint, symbol: String, size: CGFloat = 40) {
        self.tint = tint
        self.symbol = symbol
        self.size = size
    }

    init(connection: Connection, size: CGFloat = 40) {
        self.init(tint: connection.tint, symbol: connection.symbol, size: size)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
        shape
            .fill(tint.gradient)
            .overlay {
                // Soft top sheen.
                shape.fill(
                    LinearGradient(
                        colors: [.white.opacity(0.22), .white.opacity(0)],
                        startPoint: .top,
                        endPoint: .center
                    )
                )
            }
            .overlay {
                shape.strokeBorder(.white.opacity(0.18), lineWidth: max(0.5, size / 80))
            }
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.18), radius: size * 0.02, y: size * 0.015)
            }
            .frame(width: size, height: size)
            .shadow(color: tint.bottom.opacity(size > 24 ? 0.32 : 0), radius: size * 0.1, y: size * 0.05)
            .accessibilityHidden(true)
    }
}

/// The Buckets app icon, drawn in SwiftUI so the welcome screen and the
/// generated .icns are pixel-identical.
struct AppIconView: View {
    var size: CGFloat = 128

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
        ZStack {
            shape.fill(
                LinearGradient(
                    colors: [
                        Color(red: 0.40, green: 0.76, blue: 1.00),
                        Color(red: 0.13, green: 0.50, blue: 0.98),
                        Color(red: 0.05, green: 0.32, blue: 0.86),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )

            // Light bloom from the top-left.
            shape.fill(
                RadialGradient(
                    colors: [.white.opacity(0.35), .white.opacity(0)],
                    center: UnitPoint(x: 0.25, y: 0.05),
                    startRadius: 0,
                    endRadius: size * 0.75
                )
            )

            // Stacked "bucket" layers behind the cloud.
            VStack(spacing: size * 0.035) {
                ForEach(0 ..< 3) { index in
                    Capsule()
                        .fill(.white.opacity(0.16 - Double(index) * 0.04))
                        .frame(width: size * (0.56 - CGFloat(index) * 0.08), height: size * 0.05)
                }
            }
            .offset(y: size * 0.27)

            Image(systemName: "cloud.fill")
                .font(.system(size: size * 0.50, weight: .regular))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.white, Color(red: 0.88, green: 0.93, blue: 1.0)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .shadow(color: Color(red: 0.0, green: 0.15, blue: 0.5).opacity(0.35), radius: size * 0.035, y: size * 0.025)
                .offset(y: -size * 0.04)

            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: size * 0.15, weight: .heavy))
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color(red: 0.16, green: 0.56, blue: 1.0), Color(red: 0.06, green: 0.36, blue: 0.9)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            shape.strokeBorder(
                LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom),
                lineWidth: max(1, size * 0.006)
            )
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.22), radius: size * 0.045, y: size * 0.025)
        .accessibilityHidden(true)
    }
}

/// The real Finder icon for an item.
struct FileIconView: View {
    let item: BrowserItem
    var size: CGFloat = 16

    var body: some View {
        Image(nsImage: FileIcons.icon(for: item))
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Image thumbnail with a Finder-style white border; falls back to the type icon.
struct ThumbnailView: View {
    let item: BrowserItem
    let model: BrowserModel
    var size: CGFloat = 64

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .padding(2)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    .shadow(color: .black.opacity(0.22), radius: 1.5, y: 0.5)
                    .frame(width: size, height: size)
                    .transition(.opacity)
            } else {
                FileIconView(item: item, size: size)
            }
        }
        .task(id: item.etag ?? item.key) {
            guard item.isImage else { return }
            let loaded = await model.thumbnail(for: item, maxPixelSize: size * 3)
            withAnimation(.easeOut(duration: 0.2)) { image = loaded }
        }
    }
}
