import Foundation
import Observation

/// Persists connection metadata as JSON in Application Support.
/// Secrets never touch disk here — they live in the Keychain.
@Observable
final class ConnectionStore {
    private(set) var connections: [Connection] = []
    @ObservationIgnored private let fileURL: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = support.appendingPathComponent("Buckets", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        fileURL = folder.appendingPathComponent("connections.json")
        load()
    }

    func connection(withID id: UUID) -> Connection? {
        connections.first { $0.id == id }
    }

    func save(_ connection: Connection, secret: String) throws {
        try Keychain.setSecret(secret, for: connection.id)
        var updated = connection
        if let index = connections.firstIndex(where: { $0.id == connection.id }) {
            updated.revision = connections[index].revision + 1
            connections[index] = updated
        } else {
            connections.append(updated)
        }
        persist()
    }

    func delete(_ connection: Connection) {
        connections.removeAll { $0.id == connection.id }
        Keychain.deleteSecret(for: connection.id)
        persist()
    }

    @discardableResult
    func duplicate(_ connection: Connection) -> Connection {
        var copy = connection
        copy.id = UUID()
        copy.name = connection.displayName + " Copy"
        copy.createdAt = Date()
        copy.lastOpenedAt = nil
        copy.revision = 0
        if let secret = Keychain.secret(for: connection.id) {
            try? Keychain.setSecret(secret, for: copy.id)
        }
        if let index = connections.firstIndex(where: { $0.id == connection.id }) {
            connections.insert(copy, at: index + 1)
        } else {
            connections.append(copy)
        }
        persist()
        return copy
    }

    func markOpened(_ id: UUID) {
        guard let index = connections.firstIndex(where: { $0.id == id }) else { return }
        connections[index].lastOpenedAt = Date()
        persist()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        connections = (try? decoder.decode([Connection].self, from: data)) ?? []
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(connections) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
