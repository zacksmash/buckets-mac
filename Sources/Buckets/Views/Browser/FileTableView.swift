import SwiftUI

/// Finder-style list view.
struct FileTableView: View {
    @Bindable var model: BrowserModel

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
            .width(min: 160)

            TableColumn("Date Modified", value: \.sortDate) { item in
                Text(item.lastModified.map(Format.compactDate) ?? "--")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 150, ideal: 160, max: 230)

            TableColumn("Size", value: \.sortSize) { item in
                Text(item.isFolder ? "--" : Format.bytes(item.size))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .width(min: 60, ideal: 80, max: 120)
            .alignment(.numeric)

            TableColumn("Kind", value: \.kindDescription) { item in
                Text(item.kindDescription)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 80, ideal: 150, max: 200)
        } rows: {
            ForEach(model.displayedItems) { item in
                TableRow(item)
                    .itemProvider { model.dragItemProvider(for: item) }
                    .dropDestination(for: URL.self) { urls in
                        model.upload(urls, into: item.isFolder ? item.key : model.prefix)
                    }
            }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .contextMenu(forSelectionType: BrowserItem.ID.self) { ids in
            ItemContextMenu(model: model, ids: ids)
        } primaryAction: { ids in
            let items = model.items(for: ids)
            if items.count == 1, let item = items.first {
                model.open(item)
            } else if !items.isEmpty {
                model.download(ids)
            }
        }
        .browserKeyCommands(model)
        .onKeyPress(.downArrow, phases: .down) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            model.openSelection()
            return .handled
        }
    }
}
