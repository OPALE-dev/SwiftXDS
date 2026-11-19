import Foundation

/// A parsed `Content-Type` value: media type and parameters (RFC 2045 §5.1).
public struct MIMEContentType: Hashable, Sendable, CustomStringConvertible {
    /// Lower-cased `type/subtype`.
    public var mediaType: String
    /// Parameters with lower-cased names; values unquoted.
    public var parameters: [String: String]

    public init(_ mediaType: String, parameters: [String: String] = [:]) {
        self.mediaType = mediaType.lowercased()
        self.parameters = Dictionary(parameters.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
    }

    public subscript(_ name: String) -> String? { parameters[name.lowercased()] }

    /// Parses a header value; returns `nil` without a `type/subtype`.
    public init?(parsing value: String) {
        var scanner = Substring(value)
        func skipSpace() { scanner = scanner.drop(while: { $0 == " " || $0 == "\t" }) }
        skipSpace()
        let media = scanner.prefix(while: { $0 != ";" }).trimmingCharacters(in: .whitespaces)
        guard media.contains("/"), !media.hasPrefix("/"), !media.hasSuffix("/") else { return nil }
        scanner = scanner.dropFirst(scanner.prefix(while: { $0 != ";" }).count)
        var parameters: [String: String] = [:]
        while scanner.first == ";" {
            scanner = scanner.dropFirst()
            skipSpace()
            let name = scanner.prefix(while: { $0 != "=" && $0 != ";" }).trimmingCharacters(in: .whitespaces).lowercased()
            scanner = scanner.dropFirst(scanner.prefix(while: { $0 != "=" && $0 != ";" }).count)
            guard scanner.first == "=" else { continue }
            scanner = scanner.dropFirst()
            skipSpace()
            var v = ""
            if scanner.first == "\"" {
                scanner = scanner.dropFirst()
                while let c = scanner.first, c != "\"" {
                    if c == "\\", scanner.count > 1 {
                        scanner = scanner.dropFirst()
                    }
                    v.append(scanner.first!)
                    scanner = scanner.dropFirst()
                }
                scanner = scanner.dropFirst()
                scanner = scanner.drop(while: { $0 != ";" })
            } else {
                v = scanner.prefix(while: { $0 != ";" }).trimmingCharacters(in: .whitespaces)
                scanner = scanner.dropFirst(scanner.prefix(while: { $0 != ";" }).count)
            }
            if !name.isEmpty, parameters[name] == nil { parameters[name] = v }
        }
        self.init(media, parameters: parameters)
    }

    /// Header value; parameters quoted, in a stable order (`type` and `boundary` first).
    public var description: String {
        let first = ["type", "boundary", "start", "start-info", "charset", "action"]
        let keys = first.filter { parameters[$0] != nil } + parameters.keys.filter { !first.contains($0) }.sorted()
        return ([mediaType] + keys.map { k in
            let v = parameters[k]!.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            return "\(k)=\"\(v)\""
        }).joined(separator: "; ")
    }
}

/// MIME part headers, names case-insensitive, order kept.
public struct MIMEHeaders: Hashable, Sendable, Sequence {
    public private(set) var fields: [(name: String, value: String)] = []

    public init(_ fields: [(String, String)] = []) {
        self.fields = fields.map { (name: $0.0, value: $0.1) }
    }

    public subscript(_ name: String) -> String? {
        fields.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    public mutating func add(_ name: String, _ value: String) {
        fields.append((name: name, value: value))
    }

    public var contentType: MIMEContentType? { self["Content-Type"].flatMap(MIMEContentType.init(parsing:)) }

    /// `Content-ID` without its angle brackets.
    public var contentID: String? {
        self["Content-ID"].map { MIMEHeaders.unbracket($0) }
    }

    static func unbracket(_ id: String) -> String {
        var s = id.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("<"), s.hasSuffix(">") { s = String(s.dropFirst().dropLast()) }
        return s
    }

    public func makeIterator() -> IndexingIterator<[(name: String, value: String)]> { fields.makeIterator() }

    public static func == (a: MIMEHeaders, b: MIMEHeaders) -> Bool {
        a.fields.elementsEqual(b.fields) { $0.name == $1.name && $0.value == $1.value }
    }

    public func hash(into hasher: inout Hasher) {
        for f in fields { hasher.combine(f.name); hasher.combine(f.value) }
    }
}
