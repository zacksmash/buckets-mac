import Foundation

/// A tiny DOM for the small XML documents S3 returns.
final class S3XMLNode {
    let name: String
    var children: [S3XMLNode] = []
    var text = ""

    init(name: String) { self.name = name }

    func child(_ name: String) -> S3XMLNode? { children.first { $0.name == name } }
    func all(_ name: String) -> [S3XMLNode] { children.filter { $0.name == name } }
    func value(_ name: String) -> String? { child(name)?.text }
}

final class XMLTree: NSObject, XMLParserDelegate {
    private var stack: [S3XMLNode] = []
    private var root: S3XMLNode?

    static func parse(_ data: Data) -> S3XMLNode? {
        guard !data.isEmpty else { return nil }
        let builder = XMLTree()
        let parser = XMLParser(data: data)
        parser.delegate = builder
        parser.parse()
        return builder.root
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let node = S3XMLNode(name: elementName)
        if let parent = stack.last {
            parent.children.append(node)
        } else {
            root = node
        }
        stack.append(node)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack.last?.text += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        _ = stack.popLast()
    }
}

enum S3Date {
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plain = ISO8601DateFormatter()

    private static let http: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()

    static func parseISO(_ string: String) -> Date? {
        fractional.date(from: string) ?? plain.date(from: string)
    }

    static func parseHTTP(_ string: String) -> Date? {
        http.date(from: string) ?? parseISO(string)
    }
}
