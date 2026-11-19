import Foundation

/// A namespace-qualified XML name. The prefix is not part of the identity: the writer chooses it.
public struct XName: Hashable, Sendable, CustomStringConvertible {
    /// Namespace URI, or `nil` for a name in no namespace (most attributes).
    public var namespace: String?
    public var local: String

    public init(_ namespace: String?, _ local: String) {
        self.namespace = namespace
        self.local = local
    }

    /// A name in no namespace.
    public init(_ local: String) {
        self.init(nil, local)
    }

    public var description: String {
        namespace.map { "{\($0)}\(local)" } ?? local
    }
}

/// An attribute. The writer keeps the order given; the reader returns attributes sorted by name,
/// since XML gives their order no meaning.
public struct XAttribute: Hashable, Sendable {
    public var name: XName
    public var value: String

    public init(_ name: XName, _ value: String) {
        self.name = name
        self.value = value
    }
}

/// A child of an element.
public enum XNode: Hashable, Sendable {
    case element(XElement)
    case text(String)
    /// A QName as character data (SOAP fault codes): the writer binds its namespace and writes
    /// `prefix:local`. The reader returns it as `.text`; resolve it with `XElement.resolveQName`.
    case qname(XName)
    /// A well-formed XML fragment written verbatim, for content that must keep its exact bytes,
    /// such as a signed security header. It carries its own namespace declarations; the reader
    /// never produces it.
    case raw(String)
}

/// An XML element as a value: name, ordered attributes and children.
///
/// SOAP envelopes and XDS metadata are small and structured; documents travel as MTOM parts, never in
/// this tree. Mixed content is kept, but whitespace-only text between child elements is dropped on read.
public struct XElement: Hashable, Sendable {
    public var name: XName
    public var attributes: [XAttribute]
    public var children: [XNode]
    /// Prefixes in scope where the element was read (prefix → namespace; `""` is the default
    /// namespace). Empty for built elements; ignored by equality.
    public var namespaceScope: [String: String] = [:]

    public static func == (a: XElement, b: XElement) -> Bool {
        a.name == b.name && a.attributes == b.attributes && a.children == b.children
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(name)
        hasher.combine(attributes)
        hasher.combine(children)
    }

    /// Resolves a `prefix:local` value read in this element (a QName in text or an attribute);
    /// `nil` when the prefix is not declared.
    public func resolveQName(_ value: String) -> XName? {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let colon = v.firstIndex(of: ":") else {
            return XName(namespaceScope[""], v)
        }
        guard let ns = namespaceScope[String(v[..<colon])] else { return nil }
        return XName(ns, String(v[v.index(after: colon)...]))
    }

    public init(_ name: XName, attributes: [XAttribute] = [], children: [XNode] = []) {
        self.name = name
        self.attributes = attributes
        self.children = children
    }

    /// An element with child elements only.
    public init(_ name: XName, attributes: [XAttribute] = [], elements: [XElement]) {
        self.init(name, attributes: attributes, children: elements.map(XNode.element))
    }

    /// An element holding a single text value.
    public init(_ name: XName, attributes: [XAttribute] = [], text: String) {
        self.init(name, attributes: attributes, children: [.text(text)])
    }

    // MARK: Reading

    /// Child elements, in order.
    public var elements: [XElement] {
        children.compactMap { if case .element(let e) = $0 { e } else { nil } }
    }

    /// Child elements with this name.
    public func elements(named name: XName) -> [XElement] {
        elements.filter { $0.name == name }
    }

    /// First child element with this name.
    public func element(named name: XName) -> XElement? {
        for case .element(let e) in children where e.name == name { return e }
        return nil
    }

    /// Concatenated character data of the direct children.
    public var text: String {
        children.reduce(into: "") { if case .text(let t) = $1 { $0 += t } }
    }

    /// Character data with surrounding whitespace removed.
    public var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func attribute(_ name: XName) -> String? {
        attributes.first { $0.name == name }?.value
    }

    /// Attribute in no namespace.
    public func attribute(_ local: String) -> String? {
        attribute(XName(local))
    }

    /// Descendants (depth first, document order) with this name, this element excluded.
    public func descendants(named name: XName) -> [XElement] {
        var found: [XElement] = []
        func walk(_ e: XElement) {
            for child in e.elements {
                if child.name == name { found.append(child) }
                walk(child)
            }
        }
        walk(self)
        return found
    }

    // MARK: Building

    /// Sets, replaces or (with `nil`) removes an attribute.
    public mutating func setAttribute(_ name: XName, _ value: String?) {
        attributes.removeAll { $0.name == name }
        if let value { attributes.append(XAttribute(name, value)) }
    }

    public mutating func append(_ element: XElement) {
        children.append(.element(element))
    }

    public mutating func append(text: String) {
        children.append(.text(text))
    }
}
