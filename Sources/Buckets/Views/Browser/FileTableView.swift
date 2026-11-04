import SwiftUI

/// Finder-style list view.
struct FileTableView: View {
    @Bindable var model: BrowserModel
    @Binding var showInspector: Bool

    var body: some View {
        Table(of: BrowserItem.self, selection: $model.selection, sortOrder: $model.sortOrder) {
            TableColumn("Name", value: \.name) { item in
                HStack(spacing: 7) {
                    FileIconView(item: item, size: 17)
                    Text(item.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .help(item.displayPath)
            }
            .width(min: 200, ideal: 380)

            TableColumn("Date Modified", value: \.sortDate) { item in
                Text(item.lastModified.map(Format.date) ?? "--")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 110, ideal: 190)

            TableColumn("Size", value: \.sortSize) { item in
                Text(item.isFolder ? "--" : Format.bytes(item.size))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 60, ideal: 90, max: 140)

            TableColumn("Kind", value: \.kindDescription) { item in
                Text(item.kindDescription)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 80, ideal: 150)
        } rows: {
            ForEach(model.displayedItems) { item in
                TableRow(item)
                    .dropDestination(for: URL.self) { urls in
                        model.upload(urls, into: item.isFolder ? item.key : model.prefix)
                    }
            }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: BrowserItem.ID.self) { ids in
            ItemContextMenu(model: model, ids: ids, showInspector: $showInspector)
        } primaryAction: { ids in
            let items = model.items(for: ids)
            if items.count == 1, let item = items.first {
                model.open(item)
            } else if !items.isEmpty {
                model.download(ids)
            }
        }
        .onKeyPress(.space) {
            model.toggleQuickLook()
            return .handled
        }
        .onKeyPress(.return) {
            guard model.selection.count == 1 else { return .ignored }
            model.openSelection()
            return .handled
        }
        .onKeyPress(keys: [.delete, .deleteForward]) { press in
            guard press.modifiers.contains(.command) || press.key == .deleteForward else { return .ignored }
            model.requestDelete(model.selection)
            return .handled
        }
        .onKeyPress(.downArrow, phases: .down) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            model.openSelection()
            return .handled
        }
    }
}
