import SwiftUI
import AppKit

/// Toolbar button with a live progress ring, like Safari's downloads button.
struct TransfersButton: View {
    let transfers: TransferManager
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Label {
                Text("Transfers")
            } icon: {
                if transfers.hasActive {
                    ZStack {
                        Circle()
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 2)
                        Circle()
                            .trim(from: 0, to: max(0.02, transfers.overallProgress))
                            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(.linear(duration: 0.2), value: transfers.overallProgress)
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(Color.accentColor)
                    }
                    .frame(width: 16, height: 16)
                } else {
                    Image(systemName: "arrow.up.arrow.down.circle")
                }
            }
            .overlay(alignment: .topTrailing) {
                if transfers.hasFailed {
                    Circle()
                        .fill(.red)
                        .frame(width: 7, height: 7)
                        .offset(x: 3, y: -2)
                        .accessibilityLabel("A transfer failed")
                }
            }
        }
        .help(transfers.hasFailed ? "Show Transfers. Some transfers failed." : "Show Transfers")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            TransfersPopover(transfers: transfers)
        }
    }
}

struct TransfersPopover: View {
    let transfers: TransferManager

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Transfers")
                    .font(.body.weight(.semibold))
                Spacer()
                Button("Clear") { withAnimation(.easeOut(duration: 0.2)) { transfers.clearFinished() } }
                    .buttonStyle(.borderless)
                    .disabled(!transfers.hasFinished)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)

            Divider()

            if transfers.transfers.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.up.arrow.down.circle")
                        .font(.system(size: 32, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("No Transfers")
                        .font(.body.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text("Uploads and downloads appear here.")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: Self.listHeight)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(transfers.transfers) { transfer in
                            TransferRow(transfer: transfer, transfers: transfers)
                            if transfer.id != transfers.transfers.last?.id {
                                Divider().padding(.leading, 62)
                            }
                        }
                    }
                }
                // A fixed height: a popover that resizes with its rows judders as they animate away.
                .frame(height: Self.listHeight)
            }
        }
        .frame(width: 380)
    }

    private static let listHeight: CGFloat = 300
}

private struct TransferRow: View {
    let transfer: Transfer
    let transfers: TransferManager
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: FileIcons.icon(forName: transfer.name, isFolder: transfer.isFolder))
                .resizable()
                .frame(width: 34, height: 34)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: transfer.direction == .upload ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                        .font(.system(size: 14))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, transfer.direction == .upload ? Color.accentColor : Color.green)
                        .background(Circle().fill(Color(nsColor: .windowBackgroundColor)).padding(1))
                        .offset(x: 3, y: 3)
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(transfer.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                if transfer.isActive {
                    ProgressView(value: transfer.fractionCompleted)
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                        .tint(transfer.direction == .upload ? Color.accentColor : Color.green)
                }

                Text(statusText)
                    .font(.subheadline)
                    .foregroundStyle(isFailed ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
                    .lineLimit(2)
                    .monospacedDigit()
            }

            Spacer(minLength: 4)

            trailingButton
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(isHovering ? 0.04 : 0))
        .onHover { isHovering = $0 }
        .contextMenu {
            if let url = transfer.localURL, transfer.state == .completed {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Button("Open") { NSWorkspace.shared.open(url) }
                Divider()
            }
            if transfer.isActive {
                Button("Cancel") { transfers.cancel(transfer) }
            } else {
                if transfer.state != .completed {
                    Button("Retry") { transfers.retry(transfer) }
                }
                Button("Remove from List") { withAnimation(.snappy) { transfers.remove(transfer) } }
            }
        }
    }

    private var isFailed: Bool {
        if case .failed = transfer.state { return true }
        return false
    }

    @ViewBuilder private var trailingButton: some View {
        switch transfer.state {
        case .queued, .running:
            Button {
                transfers.cancel(transfer)
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .help("Cancel")
            .rowButtonStyle()
        case .completed:
            if let url = transfer.localURL {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Image(systemName: "magnifyingglass.circle.fill")
                }
                .help("Show in Finder")
                .rowButtonStyle()
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.green)
            }
        case .failed, .cancelled:
            Button {
                transfers.retry(transfer)
            } label: {
                Image(systemName: "arrow.clockwise.circle.fill")
            }
            .help("Retry")
            .rowButtonStyle()
        }
    }

    private var statusText: String {
        let verb = transfer.direction == .upload ? "Uploaded to" : "Saved to"
        switch transfer.state {
        case .queued:
            return "Waiting…"
        case .running:
            var parts: [String] = []
            if transfer.bytesTotal > 1 {
                parts.append("\(Format.bytes(transfer.bytesDone)) of \(Format.bytes(transfer.bytesTotal))")
            } else {
                parts.append("Preparing…")
            }
            if let rate = transfer.bytesPerSecond { parts.append(Format.rate(rate)) }
            if let remaining = transfer.secondsRemaining { parts.append(Format.remaining(remaining)) }
            return parts.joined(separator: " — ")
        case .completed:
            let size = transfer.bytesTotal > 1 ? "\(Format.bytes(transfer.bytesTotal)) · " : ""
            return "\(size)\(verb) \(transfer.destination)"
        case let .failed(message):
            return message
        case .cancelled:
            return "Cancelled"
        }
    }
}

private extension View {
    func rowButtonStyle() -> some View {
        self
            .font(.system(size: 16))
            .foregroundStyle(.secondary)
            .buttonStyle(.borderless)
    }
}
