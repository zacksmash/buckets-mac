import Foundation
import UniformTypeIdentifiers

struct BrowserItem: Identifiable, Hashable, Sendable {
    let key: String
    let name: String
    let isFolder: Bool
    let size: Int64
    let lastModified: Date?
    let etag: String?

    var id: String { key }

    var fileExtension: String { (name as NSString).pathExtension.lowercased() }

    var contentType: UTType {
        if isFolder { return .folder }
        guard !fileExtension.isEmpty else { return .data }
        return UTType(filenameExtension: fileExtension) ?? .data
    }

    var kindDescription: String {
        if isFolder { return "Folder" }
        if let description = contentType.localizedDescription, !description.isEmpty {
            return description
        }
        return fileExtension.isEmpty ? "Document" : "\(fileExtension.uppercased()) File"
    }

    // Sort keys used by the table.
    var sortSize: Int64 { isFolder ? -1 : size }
    var sortDate: Date { lastModified ?? .distantPast }

    var isImage: Bool {
        !isFolder && contentType.conforms(to: .image) && fileExtension != "svg"
    }

    private static let editableExtensions: Set<String> = [
        "txt", "text", "md", "markdown", "json", "jsonc", "json5", "yml", "yaml", "toml", "ini", "cfg",
        "conf", "env", "csv", "tsv", "log", "xml", "plist", "html", "htm", "css", "scss", "less",
        "js", "mjs", "cjs", "jsx", "ts", "tsx", "vue", "svelte", "svg", "sh", "bash", "zsh", "fish",
        "py", "rb", "php", "go", "rs", "swift", "kt", "java", "c", "h", "cpp", "hpp", "m", "cs",
        "sql", "graphql", "gql", "dockerfile", "gitignore", "editorconfig", "lock", "properties", "rst",
        "tex", "srt", "vtt", "webmanifest", "map",
    ]

    var isTextEditable: Bool {
        guard !isFolder else { return false }
        if Self.editableExtensions.contains(fileExtension) { return true }
        if fileExtension.isEmpty { return size < 512_000 }
        return contentType.conforms(to: .text) || contentType.conforms(to: .sourceCode)
    }

    /// Key minus the trailing slash, for display.
    var displayPath: String {
        isFolder && key.hasSuffix("/") ? String(key.dropLast()) : key
    }

    static func lastComponent(of key: String) -> String {
        var trimmed = Substring(key)
        while trimmed.hasSuffix("/") { trimmed = trimmed.dropLast() }
        if let slash = trimmed.lastIndex(of: "/") {
            return String(trimmed[trimmed.index(after: slash)...])
        }
        return String(trimmed)
    }
}

struct Breadcrumb: Identifiable, Hashable {
    let name: String
    let prefix: String
    let isRoot: Bool
    var id: String { prefix }
}
