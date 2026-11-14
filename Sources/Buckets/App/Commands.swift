import SwiftUI

// MARK: - Focused values

extension FocusedValues {
    @Entry var newConnectionAction: (() -> Void)?
    @Entry var browserModel: BrowserModel?
}

// MARK: - Menu bar

struct AppCommands: Commands {
    @FocusedValue(\.newConnectionAction) private var newConnection
    @FocusedValue(\.browserModel) private var browser
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        SidebarCommands()
        ToolbarCommands()
        InspectorCommands()

        CommandGroup(replacing: .newItem) {
            Button("New Connection…") { newConnection?() }
                .keyboardShortcut("n")
                .disabled(newConnection == nil)
            Button("New Window") { openWindow(id: "main") }
                .keyboardShortcut("n", modifiers: [.command, .option])

            Divider()

            Button("New Folder") { browser?.requestNewFolder() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(browser == nil)
            Button("New Text File…") { browser?.requestNewFile() }
                .disabled(browser == nil)
            Button("Upload Files…") { browser?.requestUpload() }
                .keyboardShortcut("u")
                .disabled(browser == nil)

            Divider()

            Button("Get Info") { browser?.isInspectorVisible.toggle() }
                .keyboardShortcut("i")
                .disabled(browser == nil)
        }

        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Download") { browser?.downloadSelection() }
                .keyboardShortcut("d", modifiers: [.command, .option])
                .disabled(browser?.selection.isEmpty ?? true)
            Button("Rename…") { browser?.requestRenameSelection() }
                .disabled(browser?.selection.count != 1)
            Button("Copy Path") { browser?.copyPaths(browser?.selection ?? []) }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(browser?.selection.isEmpty ?? true)
            Divider()
            Button("Delete…") { browser?.requestDelete(browser?.selection ?? []) }
                .disabled(browser?.selection.isEmpty ?? true)
        }

        CommandGroup(before: .toolbar) {
            Picker("View", selection: Binding(
                get: { browser?.viewMode ?? .list },
                set: { browser?.viewMode = $0 }
            )) {
                Text("as List").tag(BrowserViewMode.list)
                    .keyboardShortcut("1")
                Text("as Icons").tag(BrowserViewMode.grid)
                    .keyboardShortcut("2")
            }
            .pickerStyle(.inline)
            .disabled(browser == nil)

            if let browser {
                Menu("Sort By") {
                    SortMenu(model: browser)
                }
            } else {
                Menu("Sort By") {}
                    .disabled(true)
            }

            Divider()

            Button("Refresh") { browser?.reload() }
                .keyboardShortcut("r")
                .disabled(browser == nil)

            Divider()
        }

        CommandMenu("Go") {
            Button("Back") { browser?.goBack() }
                .keyboardShortcut("[")
                .disabled(!(browser?.canGoBack ?? false))
            Button("Forward") { browser?.goForward() }
                .keyboardShortcut("]")
                .disabled(!(browser?.canGoForward ?? false))
            Button("Enclosing Folder") { browser?.goUp() }
                .keyboardShortcut(.upArrow)
                .disabled(!(browser?.canGoUp ?? false))

            Divider()

            Button("Bucket Root") { browser?.navigate(to: "") }
                .keyboardShortcut("h", modifiers: [.command, .shift])
                .disabled(browser == nil)
            Button("All Connections") { browser?.onHome() }
                .keyboardShortcut("0", modifiers: [.command, .shift])
                .disabled(browser == nil)
        }
    }
}
