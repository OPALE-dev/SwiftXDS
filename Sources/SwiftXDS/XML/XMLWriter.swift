import Foundation

public enum XMLError: Error, Equatable, Sendable, CustomStringConvertible {
    /// A character that XML 1.0 cannot represent (control character, U+FFFE, U+FFFF).
    case invalidCharacter(UInt32)
    case invalidName(String)
    /// The parser refused the document; `line` and `column` are 1-based when known.
    case malformed(String, line: Int, column: Int)
    /// Document type declarations are refused (entity expansion, external entities).
    case doctypeRefused
    case tooLarge(limit: Int)
    case tooDeep(limit: Int)
    case empty
    /// Only UTF-8 is read (SOAP messages of IHE profiles are UTF-8).
    case unsupportedEncoding(String)
    /// A `prefix:` with no namespace declaration in scope.
    case undeclaredPrefix(String)

    public var description: String {
        switch self {
        case .invalidCharacter(let c): "character U+\(String(c, radix: 16, uppercase: true)) is not allowed in XML"
        case .invalidName(let n): "invalid XML name '\(n)'"
        case .malformed(let m, let l, let c): "malformed XML at \(l):\(c): \(m)"
        case .doctypeRefused: "document type declarations are refused"
        case .tooLarge(let n): "XML document larger than \(n) bytes"
        case .tooDeep(let n): "XML nesting deeper than \(n) levels"
        case .empty: "empty XML document"
        case .unsupportedEncoding(let e): "unsupported XML encoding \(e), UTF-8 expected"
        case .undeclaredPrefix(let p): "undeclared namespace prefix '\(p)'"
        }
    }
}

/// Serialises an `XElement` tree as UTF-8 XML.
///
/// Every namespace of the tree is declared once on the root element, with the prefixes of
/// `Namespace.preferredPrefixes` (then `ns1`, `ns2`…), so that QName values in text, such as the
/// SOAP fault code `soap:Sender`, can rely on them.
public enum XMLWriter {
    /// The `xml:` namespace (`xml:lang`), bound by definition and never declared.
    public static let xmlNamespace = "http://www.w3.org/XML/1998/namespace"

    public static func data(_ root: XElement, declaration: Bool = true) throws -> Data {
        Data(try string(root, declaration: declaration).utf8)
    }

    public static func string(_ root: XElement, declaration: Bool = true) throws -> String {
        var prefixes: [String: String] = [:]
        var order: [String] = []
        var used = Set<String>()
        func register(_ namespace: String?) {
            guard let namespace, namespace != xmlNamespace, prefixes[namespace] == nil else { return }
            var prefix = Namespace.preferredPrefixes[namespace]
            if let p = prefix, used.contains(p) { prefix = nil }
            if prefix == nil {
                var n = 1
                while used.contains("ns\(n)") { n += 1 }
                prefix = "ns\(n)"
            }
            prefixes[namespace] = prefix
            used.insert(prefix!)
            order.append(namespace)
        }
        func collect(_ e: XElement) {
            register(e.name.namespace)
            for a in e.attributes { register(a.name.namespace) }
            for child in e.children {
                switch child {
                case .element(let c): collect(c)
                case .qname(let q): register(q.namespace)
                case .text, .raw: break
                }
            }
        }
        collect(root)

        var out = declaration ? "<?xml version=\"1.0\" encoding=\"UTF-8\"?>" : ""
        func qualified(_ name: XName) throws -> String {
            try checkName(name.local)
            guard let ns = name.namespace else { return name.local }
            if ns == xmlNamespace { return "xml:" + name.local }
            return prefixes[ns]! + ":" + name.local
        }
        func write(_ e: XElement, isRoot: Bool) throws {
            let tag = try qualified(e.name)
            out += "<" + tag
            if isRoot {
                for ns in order {
                    out += " xmlns:" + prefixes[ns]! + "=\"" + (try escape(ns, attribute: true)) + "\""
                }
            }
            for a in e.attributes {
                out += " " + (try qualified(a.name)) + "=\"" + (try escape(a.value, attribute: true)) + "\""
            }
            if e.children.isEmpty {
                out += "/>"
                return
            }
            out += ">"
            for child in e.children {
                switch child {
                case .element(let c): try write(c, isRoot: false)
                case .text(let t): out += try escape(t, attribute: false)
                case .qname(let q): out += try qualified(q)
                case .raw(let fragment): out += fragment
                }
            }
            out += "</" + tag + ">"
        }
        try write(root, isRoot: true)
        return out
    }

    static func checkName(_ name: String) throws {
        guard let first = name.unicodeScalars.first,
              !CharacterSet.decimalDigits.contains(first), first != "-", first != ".",
              name.unicodeScalars.allSatisfy({ !CharacterSet.whitespacesAndNewlines.contains($0) && !":<>&\"'=/".unicodeScalars.contains($0) })
        else { throw XMLError.invalidName(name) }
    }

    static func escape(_ s: String, attribute: Bool) throws -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"" where attribute: out += "&quot;"
            case "\n" where attribute: out += "&#10;"
            case "\r": out += "&#13;"
            case "\t" where attribute: out += "&#9;"
            default:
                let v = scalar.value
                guard v == 0x9 || v == 0xA || v >= 0x20, v != 0xFFFE, v != 0xFFFF else {
                    throw XMLError.invalidCharacter(v)
                }
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}
