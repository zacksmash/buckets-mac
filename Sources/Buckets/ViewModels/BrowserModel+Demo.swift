import Foundation

extension BrowserModel {
    /// Sample listing for design reviews and screenshots, enabled with
    /// `open Buckets.app --args -DemoMode YES [-DemoSelect <name>]`. Never touches the network.
    static func demoItems(in prefix: String) -> [BrowserItem] {
        let now = Date()
        func file(_ name: String, _ size: Int64, _ hoursAgo: Double) -> BrowserItem {
            BrowserItem(key: prefix + name, name: name, isFolder: false, size: size,
                        lastModified: now.addingTimeInterval(-hoursAgo * 3600), etag: "9b2cf535f27731c974343645a3985328")
        }
        func folder(_ name: String) -> BrowserItem {
            BrowserItem(key: prefix + name + "/", name: name, isFolder: true, size: 0, lastModified: nil, etag: nil)
        }
        return [
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
    }
}
