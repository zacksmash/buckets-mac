import SwiftUI

struct ConnectionCard: View {
    let connection: Connection
    let onOpen: () -> Void
    let onOpenInNewWindow: () -> Void
    let onEdit: () -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false
    @Environment(\.colorScheme) private var colorScheme

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                ConnectionIcon(connection: connection, size: 48)
                Spacer()
            }

            Spacer(minLength: 16)

            Text(connection.displayName)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)

            HStack(spacing: 5) {
                Image(systemName: "shippingbox")
                    .font(.system(size: 10, weight: .semibold))
                Text(connection.bucket)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.top, 3)

            Divider()
                .padding(.vertical, 12)

            HStack(spacing: 6) {
                ProviderBadge(provider: connection.provider)
                Text(locationLabel)
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                    .help(connection.hostDescription)
                Spacer(minLength: 4)
                Text(lastOpenedLabel)
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(16)
        .frame(height: 178)
        .background {
            ZStack {
                // Cards sit slightly above the window: white in light mode, a lifted gray in dark mode.
                shape.fill(colorScheme == .dark ? Color.white.opacity(isHovering ? 0.085 : 0.06) : Color(nsColor: .controlBackgroundColor))
                shape.fill(
                    LinearGradient(
                        colors: [connection.tint.color.opacity(isHovering ? 0.16 : 0.09), .clear],
                        startPoint: .topLeading,
                        endPoint: UnitPoint(x: 0.7, y: 0.65)
                    )
                )
            }
        }
        .overlay {
            shape.strokeBorder(
                isHovering ? connection.tint.color.opacity(0.45) : Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.08),
                lineWidth: isHovering ? 1 : 0.5
            )
        }
        .overlay(alignment: .topTrailing) {
            Menu {
                menuContent
            } label: {
                Image(systemName: "ellipsis")
                    .font(.callout.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .glassEffect(.regular.interactive(), in: Circle())
                    .contentShape(Circle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(12)
            .opacity(isHovering ? 1 : 0)
            .help("More Actions")
        }
        .shadow(color: .black.opacity(isHovering ? 0.12 : 0.05), radius: isHovering ? 16 : 4, y: isHovering ? 8 : 2)
        .scaleEffect(isHovering ? 1.012 : 1)
        .contentShape(shape)
        .onTapGesture(perform: onOpen)
        .onHover { hovering in
            withAnimation(.snappy(duration: 0.2)) { isHovering = hovering }
        }
        .contextMenu { menuContent }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(connection.displayName), bucket \(connection.bucket)")
        .accessibilityAction(named: "Open", onOpen)
    }

    @ViewBuilder private var menuContent: some View {
        Button("Open", action: onOpen)
        Button("Open in New Window", action: onOpenInNewWindow)
        Divider()
        Button("Edit Connection…", action: onEdit)
        Button("Duplicate", action: onDuplicate)
        Divider()
        Button("Delete…", role: .destructive, action: onDelete)
    }

    /// Short, readable location: "Cloudflare", "Cloudflare · EU", or the S3 host.
    private var locationLabel: String {
        switch connection.provider {
        case .cloudflareR2:
            return connection.jurisdiction == .automatic ? "Cloudflare" : "Cloudflare · \(connection.jurisdiction.shortName)"
        case .s3Compatible:
            return connection.hostDescription
        }
    }

    private var lastOpenedLabel: String {
        guard let date = connection.lastOpenedAt else { return "Never opened" }
        return Format.relative(date).capitalizedFirst
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

struct ProviderBadge: View {
    let provider: StorageProvider

    var body: some View {
        Text(provider.shortName)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .fixedSize()
    }
}

struct AddConnectionCard: View {
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(isHovering ? 0.18 : 0.1))
                    .frame(width: 48, height: 48)
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            VStack(spacing: 2) {
                Text("New Connection")
                    .font(.system(size: 14, weight: .semibold))
                Text("Cloudflare R2 or any S3‑compatible service")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 178)
        .background(shape.fill(Color.accentColor.opacity(isHovering ? 0.05 : 0)))
        .overlay {
            shape.strokeBorder(
                isHovering ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.35),
                style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])
            )
        }
        .contentShape(shape)
        .onTapGesture(perform: action)
        .onHover { hovering in
            withAnimation(.snappy(duration: 0.2)) { isHovering = hovering }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "New Connection", action)
    }
}
