import SwiftUI
import QuickLook

struct FileBrowserView: View {
    @State private var model: BrowserModel
    @AppStorage("browserViewMode") private var viewMode: BrowserViewMode = .list
    @AppStorage("inspectorVisible") private var showInspector = false

    @State private var isDropTargeted = false

    init(
        connection: Connection,
        transfers: TransferManager,
        onHome: @escaping () -> Void,
        onEditConnection: @escaping () -> Void
    ) {
        _model = State(initialValue: BrowserModel(
            connection: connection,
            transfers: transfers,
            onHome: onHome,
            onEditConnection: onEditConnection
        ))
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .controlBackgroundColor))
            .safeAreaBar(edge: .bottom, spacing: 0) {
                PathBar(model: model)
            }
            .overlay {
                if isDropTargeted {
                    DropOverlay(folderName: model.currentFolderName)
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .top) {
                if let message = model.busyMessage {
                    BusyCapsule(message: message)
                        .padding(.top, 14)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .overlay(alignment: .bottom) {
                if let toast = model.toast {
                    ToastCapsule(toast: toast)
                        .padding(.bottom, 42)
                        .padding(.horizontal, 20)
                        .id(toast.id)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.snappy, value: model.toast)
            .animation(.snappy(duration: 0.2), value: isDropTargeted)
            .animation(.snappy, value: model.busyMessage)
            .dropDestination(for: URL.self) { urls, _ in
                model.upload(urls)
                return !urls.isEmpty
            } isTargeted: { targeted in
                isDropTargeted = targeted
            }
            .navigationTitle(model.currentFolderName)
            .navigationSubtitle(model.connection.displayName)
            .toolbar { BrowserToolbar(model: model, viewMode: $viewMode, showInspector: $showInspector) }
            .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search “\(model.currentFolderName)”")
            .inspector(isPresented: $showInspector) {
                InspectorView(model: model)
                    .inspectorColumnWidth(min: 250, ideal: 290, max: 380)
            }
            .quickLookPreview($model.quickLookURL)
            .modifier(BrowserDialogs(model: model))
            .focusedSceneValue(\.browserModel, model)
            .task { model.start() }
    }

    // MARK: - Content

    @ViewBuilder private var content: some View {
        if let error = model.loadError, model.items.isEmpty {
            ContentUnavailableView {
                Label("Couldn't Load “\(model.currentFolderName)”", systemImage: "exclamationmark.icloud")
            } description: {
                Text(error)
            } actions: {
                HStack {
                    Button("Try Again") { model.reload() }
                        .buttonStyle(.glassProminent)
                    Button("Edit Connection…") { model.onEditConnection() }
                        .buttonStyle(.glass)
                }
                .controlSize(.large)
            }
        } else if model.items.isEmpty && (model.isLoading || model.state == .idle) {
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.regular)
                Text("Loading…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.items.isEmpty {
            EmptyFolderView(
                folderName: model.currentFolderName,
                onUpload: { model.requestUpload() },
                onNewFolder: { model.requestNewFolder() }
            )
        } else if model.displayedItems.isEmpty {
            ContentUnavailableView.search(text: model.searchText)
        } else {
            switch viewMode {
            case .list:
                FileTableView(model: model, showInspector: $showInspector)
            case .grid:
                FileGridView(model: model, showInspector: $showInspector)
            }
        }
    }
}

/// The sheets, prompts and alerts the browser presents.
private struct BrowserDialogs: ViewModifier {
    @Bindable var model: BrowserModel

    @State private var newFolderName = ""
    @State private var newFileName = ""
    @State private var renameText = ""

    func body(content: Content) -> some View {
        content
            .sheet(item: $model.editingDocument) { document in
                TextEditorSheet(document: document, model: model)
            }
            .alert("New Folder", isPresented: $model.isNewFolderPromptPresented) {
                TextField("Name", text: $newFolderName)
                Button("Create") {
                    let name = newFolderName
                    Task { await model.createFolder(named: name) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Enter a name for the new folder in “\(model.currentFolderName)”.")
            }
            .alert("New Text File", isPresented: $model.isNewFilePromptPresented) {
                TextField("Name", text: $newFileName)
                Button("Create") {
                    let name = newFileName
                    Task { await model.createFile(named: name) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The file is created in “\(model.currentFolderName)” and opened for editing.")
            }
            .alert(
                "Rename",
                isPresented: Binding(isPresent: $model.renameTarget),
                presenting: model.renameTarget
            ) { item in
                TextField("Name", text: $renameText)
                Button("Rename") {
                    let name = renameText
                    Task { await model.rename(item, to: name) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { item in
                Text(item.isFolder
                    ? "Renaming a folder copies every object inside it to the new name."
                    : "Enter a new name for “\(item.name)”.")
            }
            .confirmationDialog(
                model.deletePromptTitle,
                isPresented: $model.isDeleteConfirmationPresented
            ) {
                Button("Delete", role: .destructive) {
                    Task { await model.confirmDelete() }
                }
                Button("Cancel", role: .cancel) { model.pendingDeletion = [] }
            } message: {
                Text("This permanently removes the selected items from the bucket. You can't undo this action.")
            }
            .alert(
                "Something Went Wrong",
                isPresented: Binding(isPresent: $model.errorMessage)
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.errorMessage ?? "")
            }
            .onChange(of: model.isNewFolderPromptPresented) { _, presented in
                if presented { newFolderName = "untitled folder" }
            }
            .onChange(of: model.isNewFilePromptPresented) { _, presented in
                if presented { newFileName = "untitled.txt" }
            }
            .onChange(of: model.renameTarget) { _, item in
                if let item { renameText = item.name }
            }
    }
}

private struct BrowserToolbar: ToolbarContent {
    let model: BrowserModel
    @Binding var viewMode: BrowserViewMode
    @Binding var showInspector: Bool

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            ControlGroup {
                Button {
                    model.goBack()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .disabled(!model.canGoBack)
                .help("See folders you viewed previously")

                Button {
                    model.goForward()
                } label: {
                    Label("Forward", systemImage: "chevron.right")
                }
                .disabled(!model.canGoForward)
                .help("See folders you viewed next")
            }
            .controlGroupStyle(.navigation)
        }

        ToolbarItem(placement: .primaryAction) {
            Picker("View", selection: $viewMode) {
                Label("List", systemImage: "list.bullet").tag(BrowserViewMode.list)
                Label("Icons", systemImage: "square.grid.2x2").tag(BrowserViewMode.grid)
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
            .help("Change the item arrangement")
        }

        ToolbarSpacer(.fixed, placement: .primaryAction)

        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                model.requestNewFolder()
            } label: {
                Label("New Folder", systemImage: "folder.badge.plus")
            }
            .help("New Folder (⇧⌘N)")

            Button {
                model.requestUpload()
            } label: {
                Label("Upload", systemImage: "arrow.up.doc")
            }
            .help("Upload Files (⌘U)")
        }

        ToolbarSpacer(.fixed, placement: .primaryAction)

        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                model.downloadSelection()
            } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
            .disabled(model.selection.isEmpty)
            .help("Download to your Downloads folder (⌥⌘D)")

            Button {
                model.requestDelete(model.selection)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(model.selection.isEmpty)
            .help("Delete (⌘⌫)")
        }

        ToolbarSpacer(.fixed, placement: .primaryAction)

        ToolbarItemGroup(placement: .primaryAction) {
            TransfersButton(transfers: model.transfers)

            Button {
                withAnimation(.snappy) { showInspector.toggle() }
            } label: {
                Label("Inspector", systemImage: "info.circle")
            }
            .help("Show or hide the inspector (⌃⌘I)")
        }
    }
}
