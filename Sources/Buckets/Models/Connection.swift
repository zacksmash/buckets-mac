import SwiftUI

enum StorageProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case cloudflareR2
    case s3Compatible

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .cloudflareR2: "Cloudflare R2"
        case .s3Compatible: "S3 Compatible"
        }
    }

    var shortName: String {
        switch self {
        case .cloudflareR2: "R2"
        case .s3Compatible: "S3"
        }
    }
}

enum R2Jurisdiction: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic
    case eu
    case fedramp

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic: "Default"
        case .eu: "European Union"
        case .fedramp: "FedRAMP"
        }
    }

    var shortName: String {
        switch self {
        case .automatic: "Default"
        case .eu: "EU"
        case .fedramp: "FedRAMP"
        }
    }

    var hostInfix: String {
        switch self {
        case .automatic: ""
        case .eu: ".eu"
        case .fedramp: ".fedramp"
        }
    }
}

enum ConnectionTint: String, Codable, CaseIterable, Identifiable, Sendable {
    case blue, indigo, purple, pink, red, orange, yellow, green, mint, teal, graphite

    var id: String { rawValue }

    private var components: (top: (Double, Double, Double), bottom: (Double, Double, Double)) {
        switch self {
        case .blue: ((0.36, 0.69, 1.00), (0.00, 0.43, 0.96))
        case .indigo: ((0.50, 0.49, 1.00), (0.27, 0.23, 0.86))
        case .purple: ((0.80, 0.50, 1.00), (0.56, 0.22, 0.90))
        case .pink: ((1.00, 0.47, 0.71), (0.93, 0.18, 0.46))
        case .red: ((1.00, 0.47, 0.43), (0.91, 0.17, 0.21))
        case .orange: ((1.00, 0.70, 0.32), (0.98, 0.45, 0.07))
        case .yellow: ((1.00, 0.86, 0.33), (0.96, 0.65, 0.00))
        case .green: ((0.44, 0.89, 0.52), (0.13, 0.67, 0.30))
        case .mint: ((0.42, 0.91, 0.85), (0.00, 0.69, 0.64))
        case .teal: ((0.38, 0.82, 0.96), (0.04, 0.57, 0.78))
        case .graphite: ((0.64, 0.66, 0.70), (0.38, 0.40, 0.45))
        }
    }

    var top: Color {
        let c = components.top
        return Color(red: c.0, green: c.1, blue: c.2)
    }

    var bottom: Color {
        let c = components.bottom
        return Color(red: c.0, green: c.1, blue: c.2)
    }

    var color: Color { bottom }

    var gradient: LinearGradient {
        LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
    }

    var displayName: String { rawValue.capitalized }
}

struct Connection: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var name = ""
    var provider: StorageProvider = .cloudflareR2
    var accountID = ""
    var jurisdiction: R2Jurisdiction = .automatic
    var customEndpoint = ""
    var region = ""
    var bucket = ""
    var accessKeyID = ""
    var tint: ConnectionTint = .blue
    var symbol = "cloud.fill"
    var createdAt = Date()
    var lastOpenedAt: Date?
    /// Bumped on every edit so open browsers rebuild their client.
    var revision = 0

    static let symbols = [
        "cloud.fill", "externaldrive.fill", "shippingbox.fill", "archivebox.fill",
        "server.rack", "globe.americas.fill", "photo.fill", "film.fill",
        "music.note", "doc.fill", "tray.full.fill", "cube.fill",
        "briefcase.fill", "hammer.fill", "sparkles", "leaf.fill",
    ]

    var displayName: String {
        let trimmedName = name.trimmed
        return trimmedName.isEmpty ? (bucket.isEmpty ? "Untitled" : bucket) : trimmedName
    }

    var endpointURL: URL? {
        switch provider {
        case .cloudflareR2:
            let account = accountID.trimmed
            guard !account.isEmpty,
                  account.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" })
            else { return nil }
            return URL(string: "https://\(account)\(jurisdiction.hostInfix).r2.cloudflarestorage.com")
        case .s3Compatible:
            var raw = customEndpoint.trimmed
            guard !raw.isEmpty else { return nil }
            if !raw.contains("://") { raw = "https://" + raw }
            guard let url = URL(string: raw), let host = url.host, !host.isEmpty else { return nil }
            return url
        }
    }

    var signingRegion: String {
        switch provider {
        case .cloudflareR2: return "auto"
        case .s3Compatible:
            let value = region.trimmed
            return value.isEmpty ? "us-east-1" : value
        }
    }

    var hostDescription: String { endpointURL?.host ?? "No endpoint" }

    /// Identity of everything that affects how we talk to the server.
    var sessionIdentity: String { "\(id.uuidString)-\(revision)" }
}

extension Connection {
    /// Tolerant decoding: a missing or unrecognised field falls back to its default
    /// instead of failing the whole connections file.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Connection()
        id = (try? container.decodeIfPresent(UUID.self, forKey: .id)) ?? defaults.id
        name = (try? container.decodeIfPresent(String.self, forKey: .name)) ?? defaults.name
        provider = (try? container.decodeIfPresent(StorageProvider.self, forKey: .provider)) ?? defaults.provider
        accountID = (try? container.decodeIfPresent(String.self, forKey: .accountID)) ?? defaults.accountID
        jurisdiction = (try? container.decodeIfPresent(R2Jurisdiction.self, forKey: .jurisdiction)) ?? defaults.jurisdiction
        customEndpoint = (try? container.decodeIfPresent(String.self, forKey: .customEndpoint)) ?? defaults.customEndpoint
        region = (try? container.decodeIfPresent(String.self, forKey: .region)) ?? defaults.region
        bucket = (try? container.decodeIfPresent(String.self, forKey: .bucket)) ?? defaults.bucket
        accessKeyID = (try? container.decodeIfPresent(String.self, forKey: .accessKeyID)) ?? defaults.accessKeyID
        tint = (try? container.decodeIfPresent(ConnectionTint.self, forKey: .tint)) ?? defaults.tint
        symbol = (try? container.decodeIfPresent(String.self, forKey: .symbol)) ?? defaults.symbol
        createdAt = (try? container.decodeIfPresent(Date.self, forKey: .createdAt)) ?? defaults.createdAt
        lastOpenedAt = (try? container.decodeIfPresent(Date.self, forKey: .lastOpenedAt)) ?? nil
        revision = (try? container.decodeIfPresent(Int.self, forKey: .revision)) ?? defaults.revision
    }
}
