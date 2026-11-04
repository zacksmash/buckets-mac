import SwiftUI

/// The browser window: connections sidebar + file browser for the active bucket.
struct BrowserView: View {
    @Environment(ConnectionStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    let connection: Connection
    @Binding var activeID: UUID?

    @State private var transfers = TransferManager()
    @State private var editorTarget: ConnectionEditorTarget?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(
                activeID: $activeID,
                onAdd: { editorTarget = .new },
                onEdit: { editorTarget = .edit($0) },
                onOpenInNewWindow: { openWindow(id: "connection", value: $0.id) },
                onHome: { activeID = nil }
            )
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
        } detail: {
            FileBrowserView(
                connection: connection,
                transfers: transfers,
                onHome: { activeID = nil },
                onEditConnection: { editorTarget = .edit(connection) }
            )
            .id(connection.sessionIdentity)
        }
        .focusedSceneValue(\.newConnectionAction) { editorTarget = .new }
        .sheet(item: $editorTarget) { target in
            ConnectionEditorView(connection: target.connection) { saved in
                if target.connection == nil { activeID = saved.id }
            }
        }
    }
}

struct SidebarView: View {
    @Environment(ConnectionStore.self) private var store
    @Binding var activeID: UUID?
    let onAdd: () -> Void
    let onEdit: (Connection) -> Void
    let onOpenInNewWindow: (Connection) -> Void
    let onHome: () -> Void

    var body: some View {
        List(selection: Binding(get: { activeID }, set: { if let id = $0 { activeID = id } })) {
            Section("Connections") {
                ForEach(store.connections) { connection in
                    Label {
                        Text(connection.displayName)
                            .lineLimit(1)
                    } icon: {
                        ConnectionIcon(connection: connection, size: 18)
                    }
                    .tag(connection.id)
                    .help("\(connection.bucket) · \(connection.hostDescription)")
                    .contextMenu {
                        Button("Open in New Window") { onOpenInNewWindow(connection) }
                        Divider()
                        Button("Edit Connection…") { onEdit(connection) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaBar(edge: .bottom, spacing: 0) {
            HStack(spacing: 2) {
                Button(action: onHome) {
                    Label("All Connections", systemImage: "square.grid.2x2")
                        .font(.system(size: 12))
                }
                .help("Show All Connections (⇧⌘0)")
                Spacer()
                Button(action: onAdd) {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 22, height: 22)
                }
                .help("New Connection (⌘N)")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
    }
}
