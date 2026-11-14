import SwiftUI

enum ConnectionEditorTarget: Identifiable {
    case new
    case edit(Connection)

    var id: String {
        switch self {
        case .new: "new"
        case let .edit(connection): connection.id.uuidString
        }
    }

    var connection: Connection? {
        if case let .edit(connection) = self { return connection }
        return nil
    }
}

struct ConnectionsHomeView: View {
    @Environment(ConnectionStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    let onOpen: (Connection) -> Void

    @State private var editorTarget: ConnectionEditorTarget?
    @State private var pendingDeletion: Connection?
    @State private var searchText = ""
    @State private var duplicateError: String?

    private var filteredConnections: [Connection] {
        let query = searchText.trimmed
        guard !query.isEmpty else { return store.connections }
        return store.connections.filter {
            $0.displayName.localizedCaseInsensitiveContains(query)
                || $0.bucket.localizedCaseInsensitiveContains(query)
                || $0.hostDescription.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        Group {
            if store.connections.isEmpty {
                WelcomeView { editorTarget = .new }
            } else {
                gallery
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(HomeBackground())
        .navigationTitle("Buckets")
        .toolbar {
            if !store.connections.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        editorTarget = .new
                    } label: {
                        Label("New Connection", systemImage: "plus")
                    }
                    .help("Add a new connection (⌘N)")
                }
            }
        }
        .searchableWhen(!store.connections.isEmpty, text: $searchText, prompt: "Search Connections")
        .focusedSceneValue(\.newConnectionAction) { editorTarget = .new }
        .onAppear {
            // Debug aid for screenshots: `open Buckets.app --args -DemoPresentEditor YES`
            if UserDefaults.standard.bool(forKey: "DemoPresentEditor") { editorTarget = .new }
        }
        .sheet(item: $editorTarget) { target in
            ConnectionEditorView(connection: target.connection) { saved in
                if target.connection == nil { onOpen(saved) }
            }
        }
        .confirmationDialog(
            "Delete “\(pendingDeletion?.displayName ?? "")”?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            presenting: pendingDeletion
        ) { connection in
            Button("Delete Connection", role: .destructive) {
                withAnimation(.snappy) { store.delete(connection) }
            }
        } message: { _ in
            Text("The connection and its saved secret key will be removed from this Mac. Files in the bucket aren't affected.")
        }
        .alert(
            "Couldn't Duplicate Connection",
            isPresented: Binding(
                get: { duplicateError != nil },
                set: { if !$0 { duplicateError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(duplicateError ?? "")
        }
    }

    private var gallery: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header

                if filteredConnections.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                        .frame(maxWidth: .infinity, minHeight: 280)
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 248, maximum: 340), spacing: 18)],
                        spacing: 18
                    ) {
                        ForEach(filteredConnections) { connection in
                            ConnectionCard(
                                connection: connection,
                                onOpen: { onOpen(connection) },
                                onOpenInNewWindow: { openWindow(id: "connection", value: connection.id) },
                                onEdit: { editorTarget = .edit(connection) },
                                onDuplicate: {
                                    do {
                                        try withAnimation(.snappy) { _ = try store.duplicate(connection) }
                                    } catch {
                                        duplicateError = error.localizedDescription
                                    }
                                },
                                onDelete: { pendingDeletion = connection }
                            )
                            .transition(.scale(scale: 0.92).combined(with: .opacity))
                        }

                        if searchText.trimmed.isEmpty {
                            AddConnectionCard { editorTarget = .new }
                        }
                    }
                }
            }
            .padding(.horizontal, 40)
            .padding(.top, 28)
            .padding(.bottom, 40)
            .frame(maxWidth: 1240)
            .frame(maxWidth: .infinity)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            AppIconView(size: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text("Connections")
                    .font(.system(size: 28, weight: .bold))
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var subtitle: String {
        let count = store.connections.count
        return "\(count) \(count == 1 ? "bucket" : "buckets") · Choose one to start browsing."
    }
}

/// Window background with a very soft accent bloom.
struct HomeBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            RadialGradient(
                colors: [Color.accentColor.opacity(colorScheme == .dark ? 0.10 : 0.07), .clear],
                center: .top,
                startRadius: 0,
                endRadius: 620
            )
        }
        .ignoresSafeArea()
    }
}

private extension View {
    /// Shows the toolbar search field only when there is something to search.
    @ViewBuilder
    func searchableWhen(_ enabled: Bool, text: Binding<String>, prompt: String) -> some View {
        if enabled {
            searchable(text: text, placement: .toolbar, prompt: Text(prompt))
        } else {
            self
        }
    }
}
