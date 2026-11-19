import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Reads UTF-8 XML into an `XElement` tree with namespace URIs resolved.
///
/// Hardened for documents received from other systems: document type declarations are refused
/// (no entity expansion, no external entity), and size and depth are bounded.
public enum XMLReader {
    public struct Limits: Sendable {
        public var maxBytes: Int
        public var maxDepth: Int

        public init(maxBytes: Int = 64 << 20, maxDepth: Int = 256) {
            self.maxBytes = maxBytes
            self.maxDepth = maxDepth
        }

        public static let `default` = Limits()
    }

    public static func parse(_ data: Data, limits: Limits = .default) throws -> XElement {
        guard data.count <= limits.maxBytes else { throw XMLError.tooLarge(limit: limits.maxBytes) }
        guard !data.isEmpty else { throw XMLError.empty }
        try checkEncoding(data)
        // Safe on UTF-8 only, hence the check above: a UTF-16 document would hide the declaration.
        if data.range(of: Data("<!DOCTYPE".utf8)) != nil { throw XMLError.doctypeRefused }
        let parser = XMLParser(data: data)
        let builder = TreeBuilder(maxDepth: limits.maxDepth)
        parser.delegate = builder
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = true
        parser.shouldResolveExternalEntities = false
        let ok = parser.parse()
        if let error = builder.error { throw error }
        guard ok, let root = builder.root else {
            let message = parser.parserError.map { String(describing: $0) } ?? "parse failed"
            throw XMLError.malformed(message, line: parser.lineNumber, column: parser.columnNumber)
        }
        return root
    }

    /// Refuses UTF-16 and UTF-32 (byte order marks or zero bytes in the first characters) and any
    /// declared encoding other than UTF-8.
    static func checkEncoding(_ data: Data) throws {
        let head = [UInt8](data.prefix(4))
        if head.starts(with: [0xFE, 0xFF]) || head.starts(with: [0xFF, 0xFE]) || head.contains(0) {
            throw XMLError.unsupportedEncoding("UTF-16 or UTF-32")
        }
        let start = head.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0
        guard data.dropFirst(start).starts(with: Data("<?xml".utf8)) else { return }
        let declaration = String(decoding: data.dropFirst(start).prefix(200).prefix { $0 != UInt8(ascii: ">") }, as: UTF8.self)
        guard let range = declaration.range(of: "encoding") else { return }
        let rest = declaration[range.upperBound...].drop { $0 == " " || $0 == "=" || $0 == "\t" }
        guard let quote = rest.first, quote == "\"" || quote == "'" else { return }
        let value = rest.dropFirst().prefix { $0 != quote }
        guard ["utf-8", "utf8"].contains(value.lowercased()) else { throw XMLError.unsupportedEncoding(String(value)) }
    }

    public static func parse(_ string: String, limits: Limits = .default) throws -> XElement {
        try parse(Data(string.utf8), limits: limits)
    }
}

private final class TreeBuilder: NSObject, XMLParserDelegate {
    let maxDepth: Int
    var stack: [XElement] = []
    /// In-scope prefix → namespace, one dictionary per open element.
    var scopes: [[String: String]] = [["xml": XMLWriter.xmlNamespace]]
    var pending: [String: String] = [:]
    var root: XElement?
    var error: XMLError?

    init(maxDepth: Int) { self.maxDepth = maxDepth }

    func fail(_ parser: XMLParser, _ e: XMLError) {
        if error == nil { error = e }
        parser.abortParsing()
    }

    func parser(_ parser: XMLParser, didStartMappingPrefix prefix: String, toURI namespaceURI: String) {
        pending[prefix] = namespaceURI
    }

    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
        fail(parser, .doctypeRefused)
    }

    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) {
        fail(parser, .doctypeRefused)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        guard error == nil else { return }
        guard stack.count < maxDepth else { return fail(parser, .tooDeep(limit: maxDepth)) }
        var scope = scopes.last!
        for (p, uri) in pending { scope[p] = uri }
        pending.removeAll()
        scopes.append(scope)

        var attributes: [XAttribute] = []
        for (key, value) in attributeDict.sorted(by: { $0.key < $1.key }) {
            if key == "xmlns" || key.hasPrefix("xmlns:") { continue }
            if let colon = key.firstIndex(of: ":") {
                let prefix = String(key[..<colon]), local = String(key[key.index(after: colon)...])
                guard let ns = scope[prefix] else { return fail(parser, .undeclaredPrefix(prefix)) }
                attributes.append(XAttribute(XName(ns, local), value))
            } else {
                attributes.append(XAttribute(XName(nil, key), value))
            }
        }
        var local = elementName
        let ns = (namespaceURI?.isEmpty ?? true) ? nil : namespaceURI
        if let q = qName ?? Optional(elementName), let colon = q.firstIndex(of: ":") {
            guard ns != nil else { return fail(parser, .undeclaredPrefix(String(q[..<colon]))) }
        }
        if let colon = local.firstIndex(of: ":") { local = String(local[local.index(after: colon)...]) }
        var element = XElement(XName(ns, local), attributes: attributes)
        element.namespaceScope = scope
        stack.append(element)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard error == nil, !stack.isEmpty else { return }
        if case .text(let t)? = stack[stack.count - 1].children.last {
            stack[stack.count - 1].children[stack[stack.count - 1].children.count - 1] = .text(t + string)
        } else {
            stack[stack.count - 1].children.append(.text(string))
        }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        self.parser(parser, foundCharacters: String(decoding: CDATABlock, as: UTF8.self))
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard error == nil, var element = stack.popLast() else { return }
        scopes.removeLast()
        if element.children.contains(where: { if case .element = $0 { true } else { false } }) {
            element.children.removeAll {
                if case .text(let t) = $0 { t.allSatisfy(\.isWhitespace) } else { false }
            }
        }
        if stack.isEmpty {
            root = element
        } else {
            stack[stack.count - 1].children.append(.element(element))
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        guard error == nil else { return }
        // libxml2 (FoundationXML on Linux) refuses an undeclared prefix itself, before
        // didStartElement: XML_NS_ERR_UNDEFINED_NAMESPACE, error 201.
        if (parseError as NSError).code == 201 {
            error = .undeclaredPrefix(Self.prefix(in: parseError))
            return
        }
        error = .malformed(String(describing: parseError), line: parser.lineNumber, column: parser.columnNumber)
    }

    /// The prefix named by libxml2's "Namespace prefix p … is not defined" message, when present.
    static func prefix(in error: Error) -> String {
        let text = (error as NSError).userInfo.values.compactMap { $0 as? String }.joined(separator: " ")
            + " " + String(describing: error)
        guard let range = text.range(of: "Namespace prefix ") else { return "" }
        return String(text[range.upperBound...].prefix { !$0.isWhitespace })
    }
}
