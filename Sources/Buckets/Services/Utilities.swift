import Foundation
import CryptoKit
import UniformTypeIdentifiers

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    var xmlEscaped: String {
        self.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

extension Sequence where Element == UInt8 {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

extension Data {
    var sha256Hex: String { SHA256.hash(data: self).hexString }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}

enum MIME {
    static func type(forFileName name: String) -> String {
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty,
              let type = UTType(filenameExtension: ext),
              let mime = type.preferredMIMEType
        else { return "application/octet-stream" }
        return mime
    }
}

enum Format {
    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    static func exactBytes(_ count: Int64) -> String {
        "\(count.formatted()) bytes"
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    private static let longDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .medium
        return formatter
    }()

    static func date(_ date: Date) -> String { dateFormatter.string(from: date) }
    static func longDate(_ date: Date) -> String { longDateFormatter.string(from: date) }

    static func relative(_ date: Date) -> String {
        if abs(date.timeIntervalSinceNow) < 60 { return "just now" }
        return date.formatted(.relative(presentation: .named))
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        "\(bytes(Int64(bytesPerSecond)))/s"
    }

    static func remaining(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "" }
        switch seconds {
        case ..<5: return "A few seconds remaining"
        case ..<60: return "About \(Int(seconds.rounded())) seconds remaining"
        case ..<3600:
            let minutes = Int((seconds / 60).rounded())
            return minutes <= 1 ? "About a minute remaining" : "About \(minutes) minutes remaining"
        default:
            let hours = Int((seconds / 3600).rounded())
            return hours <= 1 ? "About an hour remaining" : "About \(hours) hours remaining"
        }
    }
}
