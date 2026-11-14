import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum BrowserViewMode: String, CaseIterable, Identifiable {
    case list, grid
    var id: String { rawValue }
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
    let thumbnailCache = NSCache<NSString, NSImage>()

    @ObservationIgnored private var client: S3Client?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var reservedPaths: Set<String> = []
    @ObservationIgnored private var selectionAnchor: BrowserItem.ID?
    @ObservationIgnored private var isStarting = false

    private(set) var prefix = ""
    private(set) var backStack: [String] = []
    private(set) var forwardStack: [String] = []
    private(set) var items: [BrowserItem] = []
    private(set) var state: LoadState = .idle

    var selection: Set<BrowserItem.ID> = []
    var searchText = ""
    var sortOrder: [KeyPathComparator<BrowserItem>] = [KeyPathComparator(\BrowserItem.name, comparator: .localizedStandard)]

    var busyMessage: String?
    var errorMessage: String?
    /// ETag each open text document was loaded at, sent as If-Match on save.
    @ObservationIgnored private var editETags: [UUID: String] = [:]
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

    // Prompts presented by the view.
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
        thumbnailCache.countLimit = 400
    }

    /// Creates the client lazily so throwaway models built during view updates stay cheap.
    func start() {
        guard client == nil, !isStarting else { return }
        if UserDefaults.standard.bool(forKey: "DemoMode") {
            loadDemoContent()
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

    private func scheduleReload() {
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

    private func requireClient() throws -> S3Client {
        guard let client else { throw S3Error.notConfigured }
        return client
    }

    private func present(_ error: Error) {
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
            var keys: [String] = []
            for target in targets {
                if target.isFolder {
                    let contents = try await client.list(prefix: target.key, delimiter: nil)
                    keys += contents.objects.map(\.key)
                    keys.append(target.key)
                } else {
                    keys.append(target.key)
                }
            }
            try await client.deleteObjects(Array(Set(keys)))
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
                let contents = try await client.list(prefix: item.key, delimiter: nil)
                for object in contents.objects {
                    try await client.copyObject(from: object.key, to: newKey + object.key.dropFirst(item.key.count))
                }
                if contents.objects.isEmpty { try await client.createFolder(newKey) }
                try await client.deleteObjects(contents.objects.map(\.key))
            } else {
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

    // MARK: - Uploads

    func upload(_ urls: [URL], into destination: String? = nil) {
        guard let client else { return }
        let target = destination ?? prefix
        for url in urls {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory {
                uploadDirectory(url, into: target, client: client)
            } else {
                uploadFile(url, into: target, client: client)
            }
        }
    }

    private func uploadFile(_ url: URL, into target: String, client: S3Client) {
        let name = url.lastPathComponent
        let key = target + name
        let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let contentType = MIME.type(forFileName: name)

        transfers.enqueue(
            name: name,
            direction: .upload,
            destination: folderDescription(target),
            totalBytes: size,
            operation: { progress in
                try await client.uploadFile(url, to: key, contentType: contentType, progress: progress)
            },
            onFinish: { [weak self] success in
                guard success, let self, target == self.prefix else { return }
                self.scheduleReload()
            }
        )
    }

    private func uploadDirectory(_ directory: URL, into target: String, client: S3Client) {
        let folderName = directory.lastPathComponent
        let root = target + folderName + "/"
        let baseComponents = directory.standardizedFileURL.pathComponents.count

        transfers.enqueue(
            name: folderName,
            isFolder: true,
            direction: .upload,
            destination: folderDescription(target),
            totalBytes: 0,
            operation: { progress in
                // Gather files off the main thread.
                var files: [(url: URL, key: String, size: Int64)] = []
                let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
                if let enumerator = FileManager.default.enumerator(
                    at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
                ) {
                    while let fileURL = enumerator.nextObject() as? URL {
                        let values = try? fileURL.resourceValues(forKeys: Set(keys))
                        guard values?.isRegularFile == true else { continue }
                        let relative = fileURL.standardizedFileURL.pathComponents.dropFirst(baseComponents).joined(separator: "/")
                        files.append((fileURL, root + relative, Int64(values?.fileSize ?? 0)))
                    }
                }
                let total = max(files.reduce(Int64(0)) { $0 + $1.size }, 1)
                progress(0, total)
                try await client.createFolder(root)
                var completed: Int64 = 0
                for file in files {
                    try Task.checkCancellation()
                    let base = completed
                    try await client.uploadFile(
                        file.url, to: file.key, contentType: MIME.type(forFileName: file.url.lastPathComponent)
                    ) { sent, _ in progress(base + sent, total) }
                    completed += file.size
                    progress(completed, total)
                }
            },
            onFinish: { [weak self] _ in
                guard let self, target == self.prefix else { return }
                self.scheduleReload()
            }
        )
    }

    // MARK: - Downloads

    private var downloadsFolder: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }

    /// Finds a free name like Finder does: "photo 2.jpg".
    private func uniqueURL(in folder: URL, name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) || reservedPaths.contains(candidate.path) {
            let numbered = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            candidate = folder.appendingPathComponent(numbered)
            counter += 1
        }
        reservedPaths.insert(candidate.path)
        return candidate
    }

    func downloadSelection() {
        download(selection)
    }

    func download(_ ids: Set<BrowserItem.ID>) {
        guard let client else { return }
        for item in items(for: ids) {
            let destination = uniqueURL(in: downloadsFolder, name: item.name)
            if item.isFolder {
                downloadFolder(item, to: destination, client: client)
            } else {
                transfers.enqueue(
                    name: destination.lastPathComponent,
                    direction: .download,
                    destination: "Downloads",
                    totalBytes: item.size,
                    localURL: destination,
                    operation: { progress in
                        try await client.download(item.key, to: destination, progress: progress)
                    },
                    onFinish: { [weak self] success in
                        self?.reservedPaths.remove(destination.path)
                        if success { Self.bounceDownloads(destination) }
                    }
                )
            }
        }
    }

    private func downloadFolder(_ item: BrowserItem, to destination: URL, client: S3Client) {
        transfers.enqueue(
            name: destination.lastPathComponent,
            isFolder: true,
            direction: .download,
            destination: "Downloads",
            totalBytes: 0,
            localURL: destination,
            operation: { progress in
                let contents = try await client.list(prefix: item.key, delimiter: nil)
                let files = contents.objects.filter { !$0.key.hasSuffix("/") }
                let total = max(files.reduce(Int64(0)) { $0 + $1.size }, 1)
                progress(0, total)
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                var completed: Int64 = 0
                var skipped: [String] = []
                for object in files {
                    try Task.checkCancellation()
                    let relative = String(object.key.dropFirst(item.key.count))
                    guard let target = Self.safeLocalURL(for: relative, in: destination) else {
                        skipped.append(object.key)
                        completed += object.size
                        continue
                    }
                    let base = completed
                    // Replacing is safe here: the target is checked to sit inside our own new folder.
                    try await client.download(object.key, to: target, replaceExisting: true) { received, _ in
                        progress(base + received, total)
                    }
                    completed += object.size
                    progress(completed, total)
                }
                if !skipped.isEmpty {
                    throw DownloadError.unsafeKeys(skipped)
                }
            },
            onFinish: { [weak self] success in
                self?.reservedPaths.remove(destination.path)
                if success { Self.bounceDownloads(destination) }
            }
        )
    }

    /// Maps a key's path relative to a downloaded folder onto a local URL inside `folder`.
    /// Returns nil for anything that could escape it ("." or ".." components, or no name at all).
    nonisolated static func safeLocalURL(for relative: String, in folder: URL) -> URL? {
        let components = relative.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !components.isEmpty, !components.contains(where: { $0 == "." || $0 == ".." }) else { return nil }
        let target = components.reduce(folder) { $0.appendingPathComponent($1) }.standardizedFileURL
        let root = folder.standardizedFileURL.path
        guard target.path.hasPrefix(root.hasSuffix("/") ? root : root + "/") else { return nil }
        return target
    }

    enum DownloadError: LocalizedError {
        case unsafeKeys([String])

        var errorDescription: String? {
            switch self {
            case let .unsafeKeys(keys):
                let sample = keys.prefix(3).map { "“\($0)”" }.joined(separator: ", ")
                return keys.count == 1
                    ? "Skipped \(sample) because its name isn't safe to save on this Mac."
                    : "Skipped \(keys.count) files whose names aren't safe to save on this Mac, including \(sample)."
            }
        }
    }

    /// Makes the Downloads stack in the Dock bounce, like Safari.
    private static func bounceDownloads(_ url: URL) {
        DistributedNotificationCenter.default().post(
            name: Notification.Name("com.apple.DownloadFileFinished"),
            object: url.path
        )
    }

    // MARK: - Preview, Quick Look & editing

    func toggleQuickLook() {
        if quickLookURL != nil {
            quickLookURL = nil
        } else if let item = selectedItems.first, !item.isFolder {
            quickLook(item)
        }
    }

    func quickLook(_ item: BrowserItem) {
        guard !item.isFolder, let client else { return }
        let folder = Self.quickLookRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        guard let destination = Self.safeLocalURL(for: item.name, in: folder),
              destination.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL
        else {
            errorMessage = "“\(item.name)” can't be previewed because its name isn't safe to save on this Mac."
            return
        }
        busyMessage = "Preparing preview…"
        Task {
            defer { busyMessage = nil }
            do {
                try await client.download(item.key, to: destination) { _, _ in }
                quickLookURL = destination
            } catch {
                present(error)
            }
        }
    }

    func edit(_ item: BrowserItem) {
        guard let client else { return }
        guard item.size <= 10_000_000 else {
            errorMessage = "“\(item.name)” is too large to edit here (\(Format.bytes(item.size))). Download it instead."
            return
        }
        busyMessage = "Opening “\(item.name)”…"
        Task {
            defer { busyMessage = nil }
            do {
                // Read the ETag first: if the file changes before the GET, saving fails safe with a conflict.
                let metadata = try? await client.headObject(item.key)
                let data = try await client.getObjectData(item.key)
                let encoding: String.Encoding
                let text: String
                if let utf8 = String(data: data, encoding: .utf8) {
                    text = utf8
                    encoding = .utf8
                } else if let latin = String(data: data, encoding: .isoLatin1) {
                    text = latin
                    encoding = .isoLatin1
                } else {
                    errorMessage = "“\(item.name)” doesn't look like a text file."
                    return
                }
                editingDocument = TextDocument(
                    item: item,
                    original: text,
                    encoding: encoding,
                    contentType: metadata?.contentType ?? MIME.type(forFileName: item.name)
                )
                if let document = editingDocument {
                    editETags[document.id] = metadata?.etag ?? item.etag
                }
            } catch {
                present(error)
            }
        }
    }

    func save(_ document: TextDocument, text: String) async throws {
        let client = try requireClient()
        guard let data = text.data(using: document.encoding) else {
            throw SaveError.unencodable(document.encoding.description)
        }
        do {
            let etag = try await client.putObject(
                document.item.key, data: data, contentType: document.contentType, ifMatch: editETags[document.id]
            )
            editETags[document.id] = etag
        } catch let S3Error.service(code, _, status) where status == 412 || code == "PreconditionFailed" {
            throw SaveError.changedOnServer(document.item.name)
        } catch S3Error.http(412) {
            throw SaveError.changedOnServer(document.item.name)
        }
        thumbnailCache.removeObject(forKey: document.item.key as NSString)
        reload()
    }

    enum SaveError: LocalizedError {
        case unencodable(String)
        case changedOnServer(String)

        var errorDescription: String? {
            switch self {
            case let .unencodable(encoding):
                "This text has characters that can't be saved in the file's original encoding (\(encoding)). Remove them, or download the file and edit it elsewhere."
            case let .changedOnServer(name):
                "“\(name)” changed on the server since you opened it. Close the editor and open it again to get the latest version. Your edits weren't saved."
            }
        }
    }

    func metadata(for item: BrowserItem) async throws -> S3ObjectMetadata {
        try await requireClient().headObject(item.key)
    }

    func previewData(for item: BrowserItem, maxBytes: Int? = nil) async throws -> Data {
        try await requireClient().getObjectData(item.key, maxBytes: maxBytes)
    }

    func folderStatistics(_ item: BrowserItem) async throws -> (files: Int, bytes: Int64) {
        let contents = try await requireClient().list(prefix: item.key, delimiter: nil)
        let files = contents.objects.filter { !$0.key.hasSuffix("/") }
        return (files.count, files.reduce(Int64(0)) { $0 + $1.size })
    }

    func thumbnail(for item: BrowserItem, maxPixelSize: CGFloat = 256) async -> NSImage? {
        let cacheKey = item.key as NSString
        if let cached = thumbnailCache.object(forKey: cacheKey) { return cached }
        guard item.isImage, item.size > 0, item.size <= 8_000_000, let client else { return nil }
        guard let data = try? await client.getObjectData(item.key) else { return nil }
        let image = await Task.detached(priority: .utility) {
            Thumbnailer.thumbnail(from: data, maxPixelSize: maxPixelSize)
        }.value
        if let image { thumbnailCache.setObject(image, forKey: cacheKey) }
        return image
    }

    // MARK: - Pasteboard

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

    // MARK: - Demo content

    /// Sample listing for design reviews and screenshots, enabled with
    /// `open Buckets.app --args -DemoMode YES [-DemoSelect <name>]`. Never touches the network.
    private func loadDemoContent() {
        let now = Date()
        func file(_ name: String, _ size: Int64, _ hoursAgo: Double) -> BrowserItem {
            BrowserItem(key: prefix + name, name: name, isFolder: false, size: size,
                        lastModified: now.addingTimeInterval(-hoursAgo * 3600), etag: "9b2cf535f27731c974343645a3985328")
        }
        func folder(_ name: String) -> BrowserItem {
            BrowserItem(key: prefix + name + "/", name: name, isFolder: true, size: 0, lastModified: nil, etag: nil)
        }
        items = [
            folder("assets"), folder("backups"), folder("config"), folder("videos"),
            file("README.md", 4_812, 0.4),
            file("index.html", 18_204, 3),
            file("hero-banner.jpg", 2_418_220, 26),
            file("logo.png", 84_120, 50),
            file("app.js", 312_448, 5),
            file("styles.css", 41_002, 5),
            file("manifest.json", 1_204, 72),
            file("Quarterly Report 2026.pdf", 3_902_114, 200),
            file("site-archive.zip", 128_400_112, 400),
            file("intro.mp4", 48_220_884, 600),
            file("notes.txt", 2_310, 900),
        ]
        if let name = UserDefaults.standard.string(forKey: "DemoSelect"),
           let item = items.first(where: { $0.name == name }) {
            selection = [item.id]
        }
        state = .loaded
    }
}
