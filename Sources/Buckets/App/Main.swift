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
        BucketsApp.main()
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
