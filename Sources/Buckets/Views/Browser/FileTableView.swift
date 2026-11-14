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
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .help(item.displayPath)
                // Drag-out lives on the name cell, not the row: a row item provider takes over the
                // table's drag handling and Finder files can no longer be dropped on the list.
                .onDrag { model.dragItemProvider(for: item) ?? NSItemProvider() }
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
                // No row-level drop: it makes the table claim Finder drags and then refuse them.
                // Files dropped on the list go to the browser's own drop target (the current folder).
                TableRow(item)
            }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .contextMenu(forSelectionType: BrowserItem.ID.self) { ids in
            ItemContextMenu(model: model, ids: ids)
        } primaryAction: { ids in
            let items = model.items(for: ids)
            if items.count == 1, let item = items.first {
                model.open(item)
            } else if let file = items.first(where: { !$0.isFolder }) {
                // Opening many objects at once would mean many downloads, so preview one instead.
                model.quickLook(file)
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
