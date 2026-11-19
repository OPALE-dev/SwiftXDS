import Foundation
import SwiftXDS

/// A SOAP 1.2 fault (SOAP 1.2 Part 1 §5.4).
public struct SOAPFault: Error, Hashable, Sendable, CustomStringConvertible {
    public static let faultName = XName(Namespace.soapEnvelope, "Fault")
    public static let faultAction = "http://www.w3.org/2005/08/addressing/soap/fault"

    public enum Code: String, Sendable, CaseIterable {
        case versionMismatch = "VersionMismatch"
        case mustUnderstand = "MustUnderstand"
        case dataEncodingUnknown = "DataEncodingUnknown"
        case sender = "Sender"
        case receiver = "Receiver"
    }

    public var code: Code
    /// Subcode values, outermost first: QNames such as `{WS-Addressing}ActionNotSupported`.
    public var subcodes: [XName]
    public var reason: String
    public var reasonLanguage: String
    public var role: String?
    /// The `Detail` element's children.
    public var detail: [XElement]

    public init(code: Code, subcodes: [XName] = [], reason: String, reasonLanguage: String = "en",
                role: String? = nil, detail: [XElement] = []) {
        self.code = code
        self.subcodes = subcodes
        self.reason = reason
        self.reasonLanguage = reasonLanguage
        self.role = role
        self.detail = detail
    }

    public var description: String {
        "SOAP fault \(code.rawValue)\(subcodes.isEmpty ? "" : " (" + subcodes.map(\.local).joined(separator: ", ") + ")"): \(reason)"
    }

    static func name(_ local: String) -> XName { XName(Namespace.soapEnvelope, local) }

    public var element: XElement {
        // Code values are QNames: the writer declares their namespaces and writes their prefixes.
        func codeElement(_ name: String, value: XName, rest: ArraySlice<XName>) -> XElement {
            var e = XElement(Self.name(name), elements: [XElement(Self.name("Value"), children: [.qname(value)])])
            if let next = rest.first { e.append(codeElement("Subcode", value: next, rest: rest.dropFirst())) }
            return e
        }
        var children = [
            codeElement("Code", value: XName(Namespace.soapEnvelope, code.rawValue), rest: subcodes[...]),
            XElement(Self.name("Reason"), elements: [
                XElement(Self.name("Text"), attributes: [XAttribute(XName(XMLWriter.xmlNamespace, "lang"), reasonLanguage)], text: reason),
            ]),
        ]
        if let role { children.append(XElement(Self.name("Role"), text: role)) }
        if !detail.isEmpty { children.append(XElement(Self.name("Detail"), elements: detail)) }
        return XElement(Self.faultName, elements: children)
    }

    /// A QName value: built (`.qname` child) or read (text resolved in the element's scope).
    static func qname(_ e: XElement) -> XName? {
        for case .qname(let q) in e.children { return q }
        return e.resolveQName(e.trimmedText)
    }

    public init(element: XElement) throws {
        guard element.name == Self.faultName else { throw SOAPError.invalidFault("not a Fault element") }
        guard let codeElement = element.element(named: Self.name("Code")),
              let valueElement = codeElement.element(named: Self.name("Value"))
        else { throw SOAPError.invalidFault("missing Code/Value") }
        let value = valueElement.trimmedText
        guard let qname = Self.qname(valueElement), qname.namespace == Namespace.soapEnvelope,
              let code = Code(rawValue: qname.local)
        else { throw SOAPError.invalidFault("unknown code \(value)") }
        self.code = code
        var subcodes: [XName] = []
        var current = codeElement.element(named: Self.name("Subcode"))
        while let sub = current {
            if let v = sub.element(named: Self.name("Value")) {
                guard let q = Self.qname(v) else { throw SOAPError.invalidFault("undeclared prefix in subcode \(v.trimmedText)") }
                subcodes.append(q)
            }
            current = sub.element(named: Self.name("Subcode"))
        }
        self.subcodes = subcodes
        let text = element.element(named: Self.name("Reason"))?.elements(named: Self.name("Text")).first
        reason = text?.trimmedText ?? ""
        reasonLanguage = text?.attribute(XName(XMLWriter.xmlNamespace, "lang")) ?? ""
        role = element.element(named: Self.name("Role"))?.trimmedText
        detail = element.element(named: Self.name("Detail"))?.elements ?? []
    }
}
