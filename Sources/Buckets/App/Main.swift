import SwiftUI

/// Entry point. Supports a hidden `--render-icon <dir>` flag used by the build
/// script to render the app icon from the same SwiftUI view the app uses.
@main
@MainActor
enum Main {
    static func main() {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--render-icon"), index + 1 < arguments.count {
            IconRenderer.renderIconSet(to: URL(fileURLWithPath: arguments[index + 1]))
            return
        }
        if arguments.contains("--selftest") {
            Task {
                let status = await SelfTest.run()
                exit(status)
            }
            RunLoop.main.run()
        }
        // Leftover Quick Look copies from earlier runs.
        try? FileManager.default.removeItem(at: BrowserModel.quickLookRoot)
        try? FileManager.default.removeItem(at: DraggedObject.temporaryRoot)
        try? FileManager.default.removeItem(at: Thumbnail.temporaryRoot)
        migrateLegacyDefaults()
        BucketsApp.main()
    }

    /// Settings saved under the app's earlier bundle ID (com.maxconnect.Buckets) come along once.
    private static func migrateLegacyDefaults() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "migratedLegacyDefaults"),
              let old = UserDefaults(suiteName: "com.maxconnect.Buckets")?.persistentDomain(forName: "com.maxconnect.Buckets")
        else { return }
        for (key, value) in old where defaults.object(forKey: key) == nil { defaults.set(value, forKey: key) }
        defaults.set(true, forKey: "migratedLegacyDefaults")
    }
}

struct BucketsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = ConnectionStore()

    var body: some Scene {
        WindowGroup("Buckets", id: "main") {
            RootView()
                .environment(store)
        }
        .defaultSize(width: 1180, height: 760)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands { AppCommands() }

        WindowGroup("Bucket", id: "connection", for: UUID.self) { $connectionID in
            RootView(initialConnectionID: connectionID)
                .environment(store)
        }
        .defaultSize(width: 1180, height: 760)
        .windowToolbarStyle(.unified(showsTitle: true))
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Makes `swift run` behave like a bundled app (Dock icon, menu bar, focus).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
