import SwiftUI

/// Context menu shared by the list and icon views.
struct ItemContextMenu: View {
    let model: BrowserModel
    let ids: Set<BrowserItem.ID>
    @Binding var showInspector: Bool

    var body: some View {
        let items = model.items(for: ids)
        if items.isEmpty {
            Button("New Folder") { model.requestNewFolder() }
            Button("New Text File…") { model.requestNewFile() }
            Button("Upload Files…") { model.requestUpload() }
            Divider()
            Button("Refresh") { model.reload() }
        } else {
            if items.count == 1, let item = items.first {
                Button("Open") { model.open(item) }
                if !item.isFolder {
                    Button("Quick Look") { model.quickLook(item) }
                    if item.isTextEditable {
                        Button("Edit") { model.edit(item) }
                    }
                }
                Divider()
                Button("Rename…") { model.renameTarget = item }
            }
            Button(items.count == 1 ? "Download" : "Download \(items.count) Items") {
                model.download(ids)
            }
            Divider()
            Button("Get Info") {
                model.selection = ids
                showInspector = true
            }
            Button(items.count == 1 ? "Copy Path" : "Copy Paths") { model.copyPaths(ids) }
            Button(items.count == 1 ? "Copy S3 URI" : "Copy S3 URIs") { model.copyS3URIs(ids) }
            if items.count == 1, let item = items.first, !item.isFolder {
                Menu("Copy Share Link") {
                    ForEach(BrowserModel.ShareLinkDuration.allCases) { duration in
                        Button(duration.title) { model.copyShareLink(item, expiresIn: duration) }
                    }
                }
            }
            Divider()
            Button(items.count == 1 ? "Delete…" : "Delete \(items.count) Items…", role: .destructive) {
                model.requestDelete(ids)
            }
        }
    }
}
