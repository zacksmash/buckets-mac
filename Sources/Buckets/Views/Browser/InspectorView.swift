import SwiftUI

struct InspectorView: View {
    let model: BrowserModel

    var body: some View {
        let selected = model.selectedItems
        ScrollView {
            Group {
                if selected.count == 1, let item = selected.first {
                    ItemInspector(item: item, model: model)
                        .id(item.id)
                } else if selected.count > 1 {
                    MultipleSelectionInspector(items: selected, model: model)
                } else {
                    FolderOverviewInspector(model: model)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.001))
    }
}

// MARK: - Single item

private struct ItemInspector: View {
    let item: BrowserItem
    let model: BrowserModel

    @State private var metadata: S3ObjectMetadata?
    @State private var previewImage: NSImage?
    @State private var previewText: String?
    @State private var imageSize: CGSize?
    @State private var folderStats: (files: Int, bytes: Int64)?
    @State private var isCalculating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            preview
                .frame(maxWidth: .infinity)
                .frame(height: 170)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.system(size: 15, weight: .semibold))
                    .textSelection(.enabled)
                    .lineLimit(3)
                Text(headline)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            actions

            InspectorSection(title: "Information") {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 7) {
                    InfoRow(label: "Kind", value: item.kindDescription)
                    if item.isFolder {
                        if let folderStats {
                            InfoRow(label: "Contains", value: "\(folderStats.files.formatted()) \(folderStats.files == 1 ? "file" : "files")")
                            InfoRow(label: "Size", value: "\(Format.bytes(folderStats.bytes))")
                        }
                    } else {
                        InfoRow(label: "Size", value: "\(Format.exactBytes(item.size)) (\(Format.bytes(item.size)))")
                        if let date = item.lastModified {
                            InfoRow(label: "Modified", value: Format.date(date))
                        }
                        if let imageSize {
                            InfoRow(label: "Dimensions", value: "\(Int(imageSize.width)) × \(Int(imageSize.height))")
                        }
                        if let type = metadata?.contentType {
                            InfoRow(label: "Content Type", value: type)
                        }
                        if let cache = metadata?.cacheControl {
                            InfoRow(label: "Cache", value: cache)
                        }
                    }
                }
            }

            if item.isFolder && folderStats == nil {
                Button {
                    calculateFolder()
                } label: {
                    HStack(spacing: 6) {
                        if isCalculating { ProgressView().controlSize(.small) }
                        Text(isCalculating ? "Calculating…" : "Calculate Size")
                    }
                }
                .disabled(isCalculating)
            }

            InspectorSection(title: "Location") {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 7) {
                    InfoRow(label: "Bucket", value: model.connection.bucket)
                    InfoRow(label: "Key", value: item.key, monospaced: true)
                    if let etag = metadata?.etag ?? item.etag, !item.isFolder {
                        InfoRow(label: "ETag", value: etag, monospaced: true, compact: true)
                    }
                }
            }

            if let userMetadata = metadata?.userMetadata, !userMetadata.isEmpty {
                InspectorSection(title: "Metadata") {
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 7) {
                        ForEach(userMetadata, id: \.key) { entry in
                            InfoRow(label: entry.key, value: entry.value)
                        }
                    }
                }
            }
        }
        .task { await loadDetails() }
    }

    private var headline: String {
        if item.isFolder { return "Folder" }
        return "\(item.kindDescription) — \(Format.bytes(item.size))"
    }

    @ViewBuilder private var preview: some View {
        if let previewImage {
            Image(nsImage: previewImage)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
                .transition(.opacity)
        } else if let previewText {
            ScrollView {
                Text(previewText)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(10)
            }
            .scrollDisabled(true)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
            .mask(
                LinearGradient(colors: [.black, .black, .black.opacity(0)], startPoint: .top, endPoint: .bottom)
            )
            .transition(.opacity)
        } else {
            FileIconView(item: item, size: 120)
        }
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 8) {
            if item.isFolder {
                Button {
                    model.open(item)
                } label: {
                    Label("Open", systemImage: "folder")
                        .frame(maxWidth: .infinity)
                }
            } else {
                Button {
                    model.quickLook(item)
                } label: {
                    Label("Preview", systemImage: "eye")
                        .frame(maxWidth: .infinity)
                }
                if item.isTextEditable {
                    Button {
                        model.edit(item)
                    } label: {
                        Label("Edit", systemImage: "pencil")
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            Button {
                model.download([item.id])
            } label: {
                Label("Download", systemImage: "arrow.down.circle")
                    .frame(maxWidth: .infinity)
            }
        }
        .controlSize(.regular)
        .labelStyle(.titleOnly)
        .buttonStyle(.glass)
    }

    private func loadDetails() async {
        guard !item.isFolder else { return }
        metadata = try? await model.metadata(for: item)
        if item.isImage, item.size <= 30_000_000,
           let data = try? await model.previewData(for: item) {
            imageSize = Thumbnailer.pixelSize(of: data)
            let image = await Task.detached(priority: .userInitiated) {
                Thumbnailer.thumbnail(from: data, maxPixelSize: 900)
            }.value
            withAnimation(.easeOut(duration: 0.2)) { previewImage = image }
        } else if item.isTextEditable, item.size > 0,
                  let data = try? await model.previewData(for: item, maxBytes: 6_000) {
            let text = String(decoding: data, as: UTF8.self)
            withAnimation(.easeOut(duration: 0.2)) { previewText = text }
        }
    }

    private func calculateFolder() {
        isCalculating = true
        Task {
            folderStats = try? await model.folderStatistics(item)
            isCalculating = false
        }
    }
}

// MARK: - Multiple selection

private struct MultipleSelectionInspector: View {
    let items: [BrowserItem]
    let model: BrowserModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ZStack {
                ForEach(Array(items.prefix(3).enumerated()), id: \.element.id) { index, item in
                    FileIconView(item: item, size: 96)
                        .rotationEffect(.degrees(Double(index - 1) * 8))
                        .offset(x: CGFloat(index - 1) * 18)
                        .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 190)

            VStack(alignment: .leading, spacing: 3) {
                Text("\(items.count) Items")
                    .font(.system(size: 15, weight: .semibold))
                Text(summary)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button {
                    model.download(Set(items.map(\.id)))
                } label: {
                    Text("Download All").frame(maxWidth: .infinity)
                }
                Button(role: .destructive) {
                    model.requestDelete(Set(items.map(\.id)))
                } label: {
                    Text("Delete…").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.glass)
        }
    }

    private var summary: String {
        let folders = items.filter(\.isFolder).count
        let files = items.count - folders
        let bytes = items.reduce(Int64(0)) { $0 + $1.size }
        var parts: [String] = []
        if files > 0 { parts.append("\(files) \(files == 1 ? "file" : "files")") }
        if folders > 0 { parts.append("\(folders) \(folders == 1 ? "folder" : "folders")") }
        if bytes > 0 { parts.append(Format.bytes(bytes)) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - No selection

private struct FolderOverviewInspector: View {
    let model: BrowserModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(spacing: 14) {
                if model.prefix.isEmpty {
                    ConnectionIcon(connection: model.connection, size: 96)
                } else {
                    Image(nsImage: FileIcons.icon(forName: model.currentFolderName, isFolder: true))
                        .resizable()
                        .frame(width: 128, height: 128)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 190)

            VStack(alignment: .leading, spacing: 3) {
                Text(model.currentFolderName)
                    .font(.system(size: 15, weight: .semibold))
                Text(model.summaryText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            InspectorSection(title: "Connection") {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 7) {
                    InfoRow(label: "Name", value: model.connection.displayName)
                    InfoRow(label: "Service", value: model.connection.provider.displayName)
                    InfoRow(label: "Bucket", value: model.connection.bucket)
                    InfoRow(label: "Endpoint", value: model.connection.endpointURL?.host ?? "—", monospaced: true)
                    if model.connection.provider == .s3Compatible {
                        InfoRow(label: "Region", value: model.connection.signingRegion)
                    }
                }
            }

            if !model.prefix.isEmpty {
                InspectorSection(title: "Location") {
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 7) {
                        InfoRow(label: "Prefix", value: model.prefix, monospaced: true)
                    }
                }
            }

            Button("Edit Connection…") { model.onEditConnection() }
        }
    }
}

private struct InspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content
        }
        .padding(.top, 2)
    }
}
