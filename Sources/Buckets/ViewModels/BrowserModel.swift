import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum BrowserViewMode: String, CaseIterable, Identifiable, Codable {
    case list, grid
    var id: String { rawValue }
}

struct Toast: Equatable {
    let id = UUID()
    let message: String
    let isError: Bool
}

struct TextDocument: Identifiable {
    let id = UUID()
    let item: BrowserItem
    let original: String
    let encoding: String.Encoding
    let contentType: String
}

@MainActor
@Observable
final class BrowserModel {
    enum LoadState: Equatable { case idle, loading, loaded, failed(String) }

    let connection: Connection
    let transfers: TransferManager
    let onHome: () -> Void
    let onEditConnection: () -> Void
    let thumbnailCache = NSCache<NSString, Thumbnail>()

    @ObservationIgnored var client: S3Client?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored var reservedPaths: Set<String> = []
    @ObservationIgnored private var selectionAnchor: BrowserItem.ID?
    @ObservationIgnored private var typeaheadBuffer = ""
    @ObservationIgnored private var typeaheadDate = Date.distantPast
    @ObservationIgnored private var isStarting = false

    private(set) var prefix = ""
    private(set) var backStack: [String] = []
    private(set) var forwardStack: [String] = []
    private(set) var items: [BrowserItem] = []
    private(set) var state: LoadState = .idle

    var selection: Set<BrowserItem.ID> = []
    var searchText = ""
    var sortOrder: [KeyPathComparator<BrowserItem>] = [BrowserSortField.name.comparator(ascending: true)] {
        didSet { saveViewState() }
    }
    var viewMode: BrowserViewMode = .list {
        didSet { saveViewState() }
    }
    var isInspectorVisible = false {
        didSet { saveViewState() }
    }

    var busyMessage: String?
    /// Short-lived note shown near the bottom of the window, like "Link Copied".
    private(set) var toast: Toast?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    var errorMessage: String?
    /// ETag each open text document was loaded at, sent as If-Match on save.
    @ObservationIgnored var editETags: [UUID: String] = [:]
    var quickLookURL: URL? {
        didSet {
            // Each preview downloads into its own UUID folder; drop it once the preview closes or changes.
            if let oldValue, oldValue != quickLookURL {
                try? FileManager.default.removeItem(at: oldValue.deletingLastPathComponent())
            }
        }
    }

    static var quickLookRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Buckets/QuickLook", isDirectory: true)
    }
    var editingDocument: TextDocument?

    var isNewFolderPromptPresented = false
    var isNewFilePromptPresented = false
    var renameTarget: BrowserItem?
    var pendingDeletion: Set<BrowserItem.ID> = []
    var isDeleteConfirmationPresented = false

    init(
        connection: Connection,
        transfers: TransferManager,
        onHome: @escaping () -> Void,
        onEditConnection: @escaping () -> Void
    ) {
        self.connection = connection
        self.transfers = transfers
        self.onHome = onHome
        self.onEditConnection = onEditConnection
        if let saved = ConnectionViewState.load(for: connection.id) {
            viewMode = saved.viewMode
            isInspectorVisible = saved.isInspectorVisible
            sortOrder = [saved.sortField.comparator(ascending: saved.sortAscending)]
            prefix = saved.prefix
        }
        thumbnailCache.totalCostLimit = 200_000_000
    }

    /// Creates the client lazily so throwaway models built during view updates stay cheap.
    func start() {
        guard client == nil, !isStarting else { return }
        if UserDefaults.standard.bool(forKey: "DemoMode") {
            items = Self.demoItems(in: prefix)
            if let name = UserDefaults.standard.string(forKey: "DemoSelect"),
               let item = items.first(where: { $0.name == name }) {
                selection = [item.id]
            }
            state = .loaded
            return
        }
        isStarting = true
        state = .loading
        let connection = self.connection
        Task {
            // The Keychain may show a system prompt; never block the main thread on it.
            let secret = await Task.detached(priority: .userInitiated) {
                Keychain.secret(for: connection.id) ?? ""
            }.value
            isStarting = false
            do {
                client = try S3Client(connection: connection, secret: secret)
                load(prefix)
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - View state

    var sortField: BrowserSortField {
        get { sortOrder.first.flatMap(BrowserSortField.init(comparator:)) ?? .name }
        set { sortOrder = [newValue.comparator(ascending: newValue == sortField ? isSortAscending : newValue.defaultAscending)] }
    }

    var isSortAscending: Bool {
        get { sortOrder.first?.order != .reverse }
        set { sortOrder = [sortField.comparator(ascending: newValue)] }
    }

    private func saveViewState() {
        ConnectionViewState(
            viewMode: viewMode,
            sortField: sortField,
            sortAscending: isSortAscending,
            isInspectorVisible: isInspectorVisible,
            prefix: prefix
        ).save(for: connection.id)
    }

    // MARK: - Derived state

    var isLoading: Bool { state == .loading }

    var loadError: String? {
        if case let .failed(message) = state { return message }
        return nil
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var canGoUp: Bool { !prefix.isEmpty }

    var currentFolderName: String {
        prefix.isEmpty ? connection.bucket : BrowserItem.lastComponent(of: prefix)
    }

    var parentPrefix: String {
        var parts = prefix.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if parts.last == "" { parts.removeLast() }
        guard !parts.isEmpty else { return "" }
        parts.removeLast()
        return parts.isEmpty ? "" : parts.joined(separator: "/") + "/"
    }

    var breadcrumbs: [Breadcrumb] {
        var result = [Breadcrumb(name: connection.bucket, prefix: "", isRoot: true)]
        var running = ""
        for part in prefix.split(separator: "/") {
            running += String(part) + "/"
            result.append(Breadcrumb(name: String(part), prefix: running, isRoot: false))
        }
        return result
    }

    var displayedItems: [BrowserItem] {
        var list = items
        let query = searchText.trimmed
        if !query.isEmpty {
            list = list.filter { $0.name.localizedCaseInsensitiveContains(query) }
        }
        list.sort(using: sortOrder)
        return list.filter(\.isFolder) + list.filter { !$0.isFolder }
    }

    var selectedItems: [BrowserItem] {
        items.filter { selection.contains($0.id) }
    }

    func items(for ids: Set<BrowserItem.ID>) -> [BrowserItem] {
        items.filter { ids.contains($0.id) }
    }

    var summaryText: String {
        let count = displayedItems.count
        let noun = count == 1 ? "item" : "items"
        if !selection.isEmpty {
            let selectedBytes = selectedItems.reduce(Int64(0)) { $0 + $1.size }
            let suffix = selectedBytes > 0 ? ", \(Format.bytes(selectedBytes))" : ""
            return "\(selection.count) of \(count) selected\(suffix)"
        }
        let bytes = items.reduce(Int64(0)) { $0 + $1.size }
        return bytes > 0 ? "\(count) \(noun), \(Format.bytes(bytes))" : "\(count) \(noun)"
    }

    func folderDescription(_ prefix: String) -> String {
        prefix.isEmpty ? connection.bucket : BrowserItem.lastComponent(of: prefix)
    }

    // MARK: - Loading & navigation

    func reload() {
        load(prefix, keepSelection: true)
    }

    func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            reload()
        }
    }

    private func load(_ target: String, keepSelection: Bool = false) {
        guard let client else {
            start()
            return
        }
        loadTask?.cancel()
        if !keepSelection { selection = [] }
        state = .loading

        loadTask = Task {
            do {
                let result = try await client.list(prefix: target)
                try Task.checkCancellation()
                let folders = result.prefixes.map {
                    BrowserItem(key: $0, name: BrowserItem.lastComponent(of: $0), isFolder: true, size: 0, lastModified: nil, etag: nil)
                }
                let files = result.objects
                    .filter { $0.key != target && !$0.key.hasSuffix("/") }
                    .map {
                        BrowserItem(
                            key: $0.key,
                            name: BrowserItem.lastComponent(of: $0.key),
                            isFolder: false,
                            size: $0.size,
                            lastModified: $0.lastModified,
                            etag: $0.etag
                        )
                    }
                guard target == prefix else { return }
                let newItems = folders + files
                let ids = Set(newItems.map(\.id))
                items = newItems
                selection = selection.intersection(ids)
                state = .loaded
            } catch {
                guard !isCancellation(error), target == prefix else { return }
                state = .failed(error.localizedDescription)
            }
        }
    }

    func navigate(to newPrefix: String) {
        guard newPrefix != prefix else { return }
        backStack.append(prefix)
        forwardStack.removeAll()
        show(newPrefix)
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(prefix)
        show(previous)
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(prefix)
        show(next)
    }

    func goUp() {
        guard canGoUp else { return }
        let child = prefix
        navigate(to: parentPrefix)
        selection = [child]
    }

    private func show(_ newPrefix: String) {
        prefix = newPrefix
        saveViewState()
        searchText = ""
        items = []
        selection = []
        load(newPrefix)
    }

    func open(_ item: BrowserItem) {
        if item.isFolder {
            navigate(to: item.key)
        } else if item.isTextEditable {
            edit(item)
        } else {
            quickLook(item)
        }
    }

    func openSelection() {
        let selected = selectedItems
        if selected.count == 1, let item = selected.first { open(item) }
    }

    // MARK: - Selection helpers (icon view)

    func select(_ item: BrowserItem, extend: Bool, range: Bool) {
        let ordered = displayedItems
        if range, let anchor = selectionAnchor,
           let from = ordered.firstIndex(where: { $0.id == anchor }),
           let to = ordered.firstIndex(where: { $0.id == item.id }) {
            let bounds = min(from, to) ... max(from, to)
            selection = Set(ordered[bounds].map(\.id))
        } else if extend {
            if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
            selectionAnchor = item.id
        } else {
            selection = [item.id]
            selectionAnchor = item.id
        }
        selectionCursor = item.id
    }

    /// The item keyboard selection last moved to, so the icon view can scroll it into view.
    private(set) var selectionCursor: BrowserItem.ID?

    /// Arrow-key movement in the icon view: ±1 for left and right, ±columns for up and down.
    func moveSelection(by offset: Int, extend: Bool) {
        let ordered = displayedItems
        guard !ordered.isEmpty else { return }
        let target: Int
        if let cursor = selectionCursor.flatMap({ id in ordered.firstIndex { $0.id == id } }),
           selection.contains(ordered[cursor].id) {
            let moved = cursor + offset
            guard ordered.indices.contains(moved) else { return }
            target = moved
        } else if let first = ordered.firstIndex(where: { selection.contains($0.id) }) {
            target = offset < 0 ? first : (ordered.lastIndex { selection.contains($0.id) } ?? first)
        } else {
            target = offset < 0 ? ordered.count - 1 : 0
        }
        let item = ordered[target]
        if extend, let anchor = selectionAnchor, let from = ordered.firstIndex(where: { $0.id == anchor }) {
            selection = Set(ordered[min(from, target) ... max(from, target)].map(\.id))
        } else {
            selection = [item.id]
            selectionAnchor = item.id
        }
        selectionCursor = item.id
    }

    /// Finder's type-to-select: typing quickly builds a prefix that jumps to the first matching name.
    func typeSelect(_ characters: String) {
        let now = Date()
        typeaheadBuffer = now.timeIntervalSince(typeaheadDate) > 1 ? characters : typeaheadBuffer + characters
        typeaheadDate = now
        let ordered = displayedItems
        guard let match = ordered.first(where: {
            $0.name.range(of: typeaheadBuffer, options: [.caseInsensitive, .anchored, .diacriticInsensitive]) != nil
        }) else { return }
        selection = [match.id]
        selectionAnchor = match.id
        selectionCursor = match.id
    }

    func selectAll() {
        selection = Set(displayedItems.map(\.id))
    }

    // MARK: - Prompts

    func requestNewFolder() { isNewFolderPromptPresented = true }
    func requestNewFile() { isNewFilePromptPresented = true }

    func requestRenameSelection() {
        if let item = selectedItems.first, selection.count == 1 { renameTarget = item }
    }

    func requestDelete(_ ids: Set<BrowserItem.ID>) {
        guard !ids.isEmpty else { return }
        pendingDeletion = ids
        isDeleteConfirmationPresented = true
    }

    var deletePromptTitle: String {
        let targets = items(for: pendingDeletion)
        if targets.count == 1, let item = targets.first {
            return item.isFolder
                ? "Delete “\(item.name)” and everything in it?"
                : "Delete “\(item.name)”?"
        }
        return "Delete \(targets.count) items?"
    }

    func requestUpload() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Upload"
        panel.message = "Choose files or folders to upload to “\(currentFolderName)”."
        let destination = prefix
        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK else { return }
            self?.upload(panel.urls, into: destination)
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(panel.runModal())
        }
    }

    // MARK: - Mutations

    func requireClient() throws -> S3Client {
        guard let client else { throw S3Error.notConfigured }
        return client
    }

    func present(_ error: Error) {
        guard !isCancellation(error) else { return }
        errorMessage = error.localizedDescription
    }

    private func validatedName(_ raw: String) -> String? {
        let name = raw.trimmed
        guard !name.isEmpty else { return nil }
        if name.contains("/") {
            errorMessage = "Names can't contain “/”."
            return nil
        }
        if name == "." || name == ".." {
            errorMessage = "“\(name)” isn't a valid name."
            return nil
        }
        return name
    }

    func createFolder(named raw: String) async {
        guard let name = validatedName(raw) else { return }
        let key = prefix + name + "/"
        if items.contains(where: { $0.key == key }) {
            errorMessage = "A folder named “\(name)” already exists here."
            return
        }
        do {
            try await requireClient().createFolder(key)
            let item = BrowserItem(key: key, name: name, isFolder: true, size: 0, lastModified: nil, etag: nil)
            withAnimation(.snappy) {
                items.append(item)
                selection = [item.id]
            }
        } catch {
            present(error)
        }
    }

    func createFile(named raw: String) async {
        guard let name = validatedName(raw) else { return }
        let key = prefix + name
        if items.contains(where: { $0.key == key }) {
            errorMessage = "A file named “\(name)” already exists here."
            return
        }
        do {
            try await requireClient().putObject(key, data: Data(), contentType: MIME.type(forFileName: name))
            let item = BrowserItem(key: key, name: name, isFolder: false, size: 0, lastModified: Date(), etag: nil)
            withAnimation(.snappy) {
                items.append(item)
                selection = [item.id]
            }
            editingDocument = TextDocument(item: item, original: "", encoding: .utf8, contentType: MIME.type(forFileName: name))
        } catch {
            present(error)
        }
    }

    func confirmDelete() async {
        let targets = items(for: pendingDeletion)
        pendingDeletion = []
        guard !targets.isEmpty else { return }
        busyMessage = targets.count == 1 ? "Deleting “\(targets[0].name)”…" : "Deleting \(targets.count) items…"
        defer { busyMessage = nil }
        do {
            let client = try requireClient()
            var keys: Set<String> = []
            for target in targets {
                if target.isFolder {
                    try await client.forEachPage(prefix: target.key) { objects in
                        try await client.deleteObjects(objects.map(\.key))
                    }
                }
                keys.insert(target.key)
            }
            try await client.deleteObjects(Array(keys))
            let removed = Set(targets.map(\.id))
            withAnimation(.snappy) {
                items.removeAll { removed.contains($0.id) }
            }
            selection.subtract(removed)
        } catch {
            present(error)
            reload()
        }
    }

    enum RenameError: LocalizedError {
        case tooLarge(String, moved: Bool)

        var errorDescription: String? {
            switch self {
            case let .tooLarge(name, moved):
                "“\(name)” is larger than 5 GB, which is too big to rename in place."
                    + (moved ? " Some items were already copied to the new name; the rest were left where they were." : "")
            }
        }
    }

    func rename(_ item: BrowserItem, to raw: String) async {
        guard let name = validatedName(raw), name != item.name else { return }
        let parent = String(item.key.dropLast(item.isFolder ? item.name.count + 1 : item.name.count))
        let newKey = parent + name + (item.isFolder ? "/" : "")
        if items.contains(where: { $0.key == newKey }) {
            errorMessage = "An item named “\(name)” already exists here."
            return
        }
        busyMessage = "Renaming “\(item.name)”…"
        defer { busyMessage = nil }
        do {
            let client = try requireClient()
            if item.isFolder {
                var movedAny = false
                try await client.forEachPage(prefix: item.key) { objects in
                    for object in objects {
                        guard object.size <= S3Client.maximumCopySize else {
                            throw RenameError.tooLarge(String(object.key.dropFirst(item.key.count)), moved: movedAny)
                        }
                        try await client.copyObject(from: object.key, to: newKey + object.key.dropFirst(item.key.count))
                        movedAny = true
                    }
                    try await client.deleteObjects(objects.map(\.key))
                }
                if !movedAny { try await client.createFolder(newKey) }
            } else {
                guard item.size <= S3Client.maximumCopySize else { throw RenameError.tooLarge(item.name, moved: false) }
                try await client.copyObject(from: item.key, to: newKey)
                try await client.deleteObject(item.key)
            }
            let renamed = BrowserItem(
                key: newKey, name: name, isFolder: item.isFolder, size: item.size,
                lastModified: item.isFolder ? nil : Date(), etag: item.etag
            )
            withAnimation(.snappy) {
                items.removeAll { $0.id == item.id }
                items.append(renamed)
            }
            selection = [renamed.id]
        } catch {
            present(error)
            reload()
        }
    }

    // MARK: - Toasts

    func showToast(_ message: String, isError: Bool = false) {
        toast = Toast(message: message, isError: isError)
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(isError ? 4 : 2))
            guard !Task.isCancelled else { return }
            toast = nil
        }
    }

    // MARK: - Pasteboard

    enum ShareLinkDuration: Int, CaseIterable, Identifiable {
        case hour = 3600
        case day = 86400
        case week = 604_800

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .hour: "1 Hour"
            case .day: "1 Day"
            case .week: "7 Days"
            }
        }
    }

    func copyShareLink(_ item: BrowserItem, expiresIn duration: ShareLinkDuration) {
        guard !item.isFolder else { return }
        do {
            let url = try requireClient().presignedURL(for: item.key, expiresIn: duration.rawValue)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
            showToast("Share link copied. It works for \(duration.title.lowercased()).")
        } catch {
            showToast(error.localizedDescription, isError: true)
        }
    }

    func copyPaths(_ ids: Set<BrowserItem.ID>) {
        let paths = items(for: ids).map(\.key)
        guard !paths.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
    }

    func copyS3URIs(_ ids: Set<BrowserItem.ID>) {
        let uris = items(for: ids).map { "s3://\(connection.bucket)/\($0.key)" }
        guard !uris.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(uris.joined(separator: "\n"), forType: .string)
    }
}
