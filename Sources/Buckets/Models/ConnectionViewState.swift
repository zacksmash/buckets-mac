import Foundation

enum BrowserSortField: String, CaseIterable, Identifiable, Codable {
    case name, dateModified, size, kind

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: "Name"
        case .dateModified: "Date Modified"
        case .size: "Size"
        case .kind: "Kind"
        }
    }

    /// Like Finder, dates and sizes start with the newest and largest.
    var defaultAscending: Bool { self == .name || self == .kind }

    func comparator(ascending: Bool) -> KeyPathComparator<BrowserItem> {
        let order: SortOrder = ascending ? .forward : .reverse
        return switch self {
        case .name: KeyPathComparator(\BrowserItem.name, comparator: .localizedStandard, order: order)
        case .dateModified: KeyPathComparator(\BrowserItem.sortDate, order: order)
        case .size: KeyPathComparator(\BrowserItem.sortSize, order: order)
        case .kind: KeyPathComparator(\BrowserItem.kindDescription, comparator: .localizedStandard, order: order)
        }
    }

    init?(comparator: KeyPathComparator<BrowserItem>) {
        switch comparator.keyPath {
        case \BrowserItem.name: self = .name
        case \BrowserItem.sortDate: self = .dateModified
        case \BrowserItem.sortSize: self = .size
        case \BrowserItem.kindDescription: self = .kind
        default: return nil
        }
    }
}

/// How a connection's browser was last left, restored the next time it opens.
struct ConnectionViewState: Codable {
    var viewMode: BrowserViewMode
    var sortField: BrowserSortField
    var sortAscending: Bool
    var isInspectorVisible: Bool
    var prefix: String

    private static let defaultsKey = "connectionViewStates"

    private static func all() -> [String: ConnectionViewState] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return [:] }
        return (try? JSONDecoder().decode([String: ConnectionViewState].self, from: data)) ?? [:]
    }

    static func load(for id: UUID) -> ConnectionViewState? {
        all()[id.uuidString]
    }

    func save(for id: UUID) {
        var states = Self.all()
        states[id.uuidString] = self
        if let data = try? JSONEncoder().encode(states) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}
