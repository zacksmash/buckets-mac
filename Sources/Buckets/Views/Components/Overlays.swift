import SwiftUI

/// Accent-tinted frame shown while files are dragged over the browser.
struct DropOverlay: View {
    let folderName: String

    var body: some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.accentColor.opacity(0.07))
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: 3)

            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 18))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.accentColor)
                Text("Drop to upload to “\(folderName)”")
                    .font(.system(size: 13, weight: .semibold))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .floatingCapsule()
            .padding(.bottom, 24)
        }
        .padding(6)
        .allowsHitTesting(false)
    }
}

/// Small floating status capsule for short operations.
struct BusyCapsule: View {
    let message: String

    var body: some View {
        HStack(spacing: 9) {
            ProgressView()
                .controlSize(.small)
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .floatingCapsule()
    }
}

/// Transient note in the BusyCapsule style; errors get a warning symbol instead of a spinner.
struct ToastCapsule: View {
    let toast: Toast

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: toast.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(toast.isError ? Color.orange : Color.green)
            Text(toast.message)
                .font(.callout.weight(.medium))
                .lineLimit(2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .floatingCapsule()
        .accessibilityElement(children: .combine)
    }
}

/// Shown when a folder has no contents.
struct EmptyFolderView: View {
    let folderName: String
    let onUpload: () -> Void
    let onNewFolder: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.10))
                    .frame(width: 104, height: 104)
                Circle()
                    .strokeBorder(Color.accentColor.opacity(0.25), style: StrokeStyle(lineWidth: 1.5, dash: [5, 5]))
                    .frame(width: 104, height: 104)
                Image(systemName: "tray.and.arrow.down")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(Color.accentColor)
            }
            .padding(.bottom, 20)

            Text("“\(folderName)” Is Empty")
                .font(.system(size: 20, weight: .semibold))

            Text("Drag files or folders here from the Finder to upload them, or create a new folder.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
                .padding(.top, 6)

            HStack(spacing: 10) {
                Button(action: onUpload) {
                    Label("Upload Files…", systemImage: "arrow.up.doc")
                }
                .buttonStyle(.glassProminent)

                Button(action: onNewFolder) {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.glass)
            }
            .controlSize(.large)
            .padding(.top, 22)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A secondary label/value row for inspectors and forms.
struct InfoRow: View {
    let label: String
    let value: String
    var monospaced = false
    /// Single line with middle truncation, for hashes and long keys.
    var compact = false

    static let labelWidth: CGFloat = 78

    var body: some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: Self.labelWidth, alignment: .trailing)
            Text(value)
                .font(monospaced ? .system(size: 11, design: .monospaced) : .system(size: 12))
                .textSelection(.enabled)
                .lineLimit(compact ? 1 : 4)
                .truncationMode(.middle)
                .help(compact ? value : "")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 12))
    }
}

extension View {
    /// Floating Liquid Glass capsule for transient overlays.
    func floatingCapsule() -> some View {
        glassEffect(.regular, in: Capsule())
    }
}
