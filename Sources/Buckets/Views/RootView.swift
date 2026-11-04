import SwiftUI

/// Switches a window between the connections gallery and a bucket browser.
struct RootView: View {
    @Environment(ConnectionStore.self) private var store
    @State private var activeID: UUID?

    init(initialConnectionID: UUID? = nil) {
        // Debug aid for screenshots: `open Buckets.app --args -OpenConnection <uuid>`
        let launchID = UserDefaults.standard.string(forKey: "OpenConnection").flatMap(UUID.init(uuidString:))
        _activeID = State(initialValue: initialConnectionID ?? launchID)
    }

    var body: some View {
        ZStack {
            if let id = activeID, let connection = store.connection(withID: id) {
                BrowserView(connection: connection, activeID: $activeID)
                    .transition(.opacity)
            } else {
                ConnectionsHomeView { connection in
                    activeID = connection.id
                }
                .transition(.opacity)
            }
        }
        .frame(minWidth: 820, minHeight: 540)
        .animation(.smooth(duration: 0.28), value: activeID)
        .onChange(of: activeID, initial: true) { _, id in
            if let id { store.markOpened(id) }
        }
    }
}
