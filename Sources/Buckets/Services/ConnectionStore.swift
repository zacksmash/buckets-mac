import Foundation
import Observation
import os

/// Persists connection metadata as JSON in Application Support.
/// Secrets never touch disk here — they live in the Keychain.
@Observable
final class ConnectionStore {
    private(set) var connections: [Connection] = []
    @ObservationIgnored private let fileURL: URL
    /// Set when the file couldn't be read or backed up, so we never write over it.
    @ObservationIgnored private var persistBlocked = false

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

    private static let logger = Logger(subsystem: "com.maxconnect.Buckets", category: "ConnectionStore")

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            connections = try decoder.decode([Connection].self, from: data)
        } catch {
            Self.logger.error("Couldn't read connections.json: \(error.localizedDescription, privacy: .public)")
            backUpUnreadableFile()
        }
    }

    /// Keeps a copy of a file we couldn't read, so the next save doesn't lose it for good.
    private func backUpUnreadableFile() {
        let stamp = Int(Date().timeIntervalSince1970)
        let backup = fileURL.deletingLastPathComponent().appendingPathComponent("connections.json.bak-\(stamp)")
        do {
            try FileManager.default.copyItem(at: fileURL, to: backup)
            Self.logger.notice("Backed up unreadable connections.json to \(backup.path, privacy: .public)")
        } catch {
            persistBlocked = true
            Self.logger.error("Couldn't back up connections.json: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func persist() {
        guard !persistBlocked else {
            Self.logger.error("Not saving connections.json: the existing file couldn't be read or backed up")
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(connections)
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            Self.logger.error("Couldn't save connections.json: \(error.localizedDescription, privacy: .public)")
        }
    }
}
