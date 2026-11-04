import SwiftUI

/// Finder-style path bar along the bottom of the browser.
struct PathBar: View {
    let model: BrowserModel

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 1) {
                        ForEach(Array(model.breadcrumbs.enumerated()), id: \.element.id) { index, crumb in
                            if index > 0 {
                                Image(systemName: "chevron.compact.right")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 1)
                            }
                            PathBarSegment(
                                crumb: crumb,
                                connection: model.connection,
                                isCurrent: index == model.breadcrumbs.count - 1
                            ) {
                                model.navigate(to: crumb.prefix)
                            } onDrop: { urls in
                                model.upload(urls, into: crumb.prefix)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                }
                .defaultScrollAnchor(.trailing)

                Spacer(minLength: 0)

                if model.isLoading && !model.items.isEmpty {
                    ProgressView()
                        .controlSize(.mini)
                }

                Text(model.summaryText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.trailing, 12)
            }
            .frame(height: 28)
        }
        .background(.bar)
    }
}

private struct PathBarSegment: View {
    let crumb: Breadcrumb
    let connection: Connection
    let isCurrent: Bool
    let action: () -> Void
    let onDrop: ([URL]) -> Void

    @State private var isHovering = false
    @State private var isTargeted = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if crumb.isRoot {
                    ConnectionIcon(connection: connection, size: 14)
                } else {
                    Image(nsImage: FileIcons.icon(forName: crumb.name, isFolder: true))
                        .resizable()
                        .frame(width: 15, height: 15)
                }
                Text(crumb.name)
                    .font(.system(size: 11, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? .primary : .secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isTargeted ? Color.accentColor.opacity(0.25) : Color.primary.opacity(isHovering ? 0.08 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .dropDestination(for: URL.self) { urls, _ in
            onDrop(urls)
            return true
        } isTargeted: { isTargeted = $0 }
        .help(crumb.isRoot ? "\(connection.bucket) (bucket root)" : crumb.prefix)
    }
}
