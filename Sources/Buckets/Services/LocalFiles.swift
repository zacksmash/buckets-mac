import Foundation

/// Where downloaded objects land on this Mac.
enum LocalFiles {
    static var downloadsFolder: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }

    /// Finds a free name like Finder does: "photo 2.jpg". Paths in `reserved` count as taken.
    static func uniqueURL(in folder: URL, name: String, reserved: Set<String> = []) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) || reserved.contains(candidate.path) {
            let numbered = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            candidate = folder.appendingPathComponent(numbered)
            counter += 1
        }
        return candidate
    }

    /// Maps a key's path relative to a downloaded folder onto a local URL inside `folder`.
    /// Returns nil for anything that could escape it ("." or ".." components, or no name at all).
    static func safeURL(for relative: String, in folder: URL) -> URL? {
        let components = relative.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !components.isEmpty, !components.contains(where: { $0 == "." || $0 == ".." }) else { return nil }
        let target = components.reduce(folder) { $0.appendingPathComponent($1) }.standardizedFileURL
        let root = folder.standardizedFileURL.path
        guard target.path.hasPrefix(root.hasSuffix("/") ? root : root + "/") else { return nil }
        return target
    }
}
