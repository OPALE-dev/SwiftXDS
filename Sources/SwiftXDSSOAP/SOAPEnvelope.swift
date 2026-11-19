import Foundation
import SwiftXDS

public enum SOAPError: Error, Equatable, Sendable, CustomStringConvertible {
    case notAnEnvelope(XName)
    /// SOAP 1.1 or another envelope version.
    case versionMismatch(String?)
    case missingBody
    case missingHeader(XName)
    case invalidFault(String)

    public var description: String {
        switch self {
        case .notAnEnvelope(let n): "not a SOAP envelope: \(n)"
        case .versionMismatch(let ns): "SOAP 1.2 expected, envelope namespace \(ns ?? "none")"
        case .missingBody: "SOAP envelope without Body"
        case .missingHeader(let n): "missing SOAP header \(n)"
        case .invalidFault(let m): "invalid SOAP fault: \(m)"
        }
    }
}

/// A SOAP 1.2 envelope: header blocks and body content.
public struct SOAPEnvelope: Hashable, Sendable {
    public static let envelopeName = XName(Namespace.soapEnvelope, "Envelope")
    public static let headerName = XName(Namespace.soapEnvelope, "Header")
    public static let bodyName = XName(Namespace.soapEnvelope, "Body")
    public static let mustUnderstand = XName(Namespace.soapEnvelope, "mustUnderstand")

    /// Header blocks.
    public var headers: [XElement]
    /// Header blocks written verbatim after `headers`: well-formed fragments with their own
    /// namespace declarations, never rewritten (exclusive canonicalisation stays valid).
    public var rawHeaders: [String]
    public var body: [XElement]
    /// Attributes of `Header` and `Body`, such as `wsu:Id` referenced by a signature.
    public var headerAttributes: [XAttribute]
    public var bodyAttributes: [XAttribute]

    public init(headers: [XElement] = [], rawHeaders: [String] = [], body: [XElement],
                headerAttributes: [XAttribute] = [], bodyAttributes: [XAttribute] = []) {
        self.headers = headers
        self.rawHeaders = rawHeaders
        self.body = body
        self.headerAttributes = headerAttributes
        self.bodyAttributes = bodyAttributes
    }

    /// The first body element: the request or response of a transaction, or a `Fault`.
    public var payload: XElement? { body.first }

    /// The fault carried by the body; `nil` when the body is not a fault. A fault that cannot be
    /// read is reported as an error rather than hidden.
    public func fault() throws -> SOAPFault? {
        guard let p = payload, p.name == SOAPFault.faultName else { return nil }
        return try SOAPFault(element: p)
    }

    public func header(named name: XName) -> XElement? {
        headers.first { $0.name == name }
    }

    public var element: XElement {
        var children: [XElement] = []
        if !headers.isEmpty || !rawHeaders.isEmpty || !headerAttributes.isEmpty {
            children.append(XElement(Self.headerName, attributes: headerAttributes,
                                     children: headers.map(XNode.element) + rawHeaders.map(XNode.raw)))
        }
        children.append(XElement(Self.bodyName, attributes: bodyAttributes, elements: body))
        return XElement(Self.envelopeName, elements: children)
    }

    public init(element: XElement) throws {
        guard element.name.local == "Envelope" else { throw SOAPError.notAnEnvelope(element.name) }
        guard element.name.namespace == Namespace.soapEnvelope else {
            throw SOAPError.versionMismatch(element.name.namespace)
        }
        guard let body = element.element(named: Self.bodyName) else { throw SOAPError.missingBody }
        let header = element.element(named: Self.headerName)
        self.headers = header?.elements ?? []
        self.rawHeaders = []
        self.headerAttributes = header?.attributes ?? []
        self.body = body.elements
        self.bodyAttributes = body.attributes
    }

    public func data() throws -> Data {
        try XMLWriter.data(element)
    }

    public init(data: Data, limits: XMLReader.Limits = .default) throws {
        try self.init(element: XMLReader.parse(data, limits: limits))
    }
}

/// WS-Addressing 1.0 message headers, as IHE web services use them (ITI TF-2 Appendix V).
public struct WSAddressing: Hashable, Sendable {
    public static let anonymous = "http://www.w3.org/2005/08/addressing/anonymous"
    static func name(_ local: String) -> XName { XName(Namespace.addressing, local) }

    public var action: String
    public var messageID: String?
    public var to: String?
    /// Requests: where to answer; IHE synchronous exchanges use the anonymous address.
    public var replyTo: String?
    /// Responses: the request's message ID.
    public var relatesTo: String?

    public init(action: String, messageID: String? = nil, to: String? = nil, replyTo: String? = nil, relatesTo: String? = nil) {
        self.action = action
        self.messageID = messageID
        self.to = to
        self.replyTo = replyTo
        self.relatesTo = relatesTo
    }

    /// Request headers: a fresh `urn:uuid:` message ID, anonymous reply address.
    public static func request(action: String, to: String?) -> WSAddressing {
        WSAddressing(action: action, messageID: "urn:uuid:" + UUID().uuidString.lowercased(), to: to, replyTo: anonymous)
    }

    /// Response headers for a request.
    public func response(action: String) -> WSAddressing {
        WSAddressing(action: action, messageID: "urn:uuid:" + UUID().uuidString.lowercased(), relatesTo: messageID)
    }

    /// Header blocks; `Action` and `To` carry `mustUnderstand="true"` as Appendix V requires.
    ///
    /// A receiver must fault headers it does not understand that are marked mustUnderstand:
    /// see `SOAPEnvelope.notUnderstoodHeaders(understood:)`.
    public var headers: [XElement] {
        let must = [XAttribute(SOAPEnvelope.mustUnderstand, "true")]
        var out = [XElement(Self.name("Action"), attributes: must, text: action)]
        if let messageID { out.append(XElement(Self.name("MessageID"), text: messageID)) }
        if let replyTo {
            out.append(XElement(Self.name("ReplyTo"), elements: [XElement(Self.name("Address"), text: replyTo)]))
        }
        if let to { out.append(XElement(Self.name("To"), attributes: must, text: to)) }
        if let relatesTo { out.append(XElement(Self.name("RelatesTo"), text: relatesTo)) }
        return out
    }

    public init(headers: [XElement]) throws {
        func value(_ local: String) -> String? {
            headers.first { $0.name == Self.name(local) }?.trimmedText
        }
        guard let action = value("Action"), !action.isEmpty else { throw SOAPError.missingHeader(Self.name("Action")) }
        self.action = action
        messageID = value("MessageID")
        to = value("To")
        relatesTo = value("RelatesTo")
        replyTo = headers.first { $0.name == Self.name("ReplyTo") }?.element(named: Self.name("Address"))?.trimmedText
    }
}

extension SOAPEnvelope {
    /// Headers marked `mustUnderstand` (`true` or `1`) whose names are not in `understood`: a
    /// receiver answers them with a `MustUnderstand` fault (SOAP 1.2 Part 1 §5.2.3).
    public func notUnderstoodHeaders(understood: Set<XName>) -> [XElement] {
        headers.filter { h in
            let v = h.attribute(Self.mustUnderstand)?.trimmingCharacters(in: .whitespaces)
            return (v == "true" || v == "1") && !understood.contains(h.name)
        }
    }

    /// An envelope with WS-Addressing headers, then any additional header blocks (for example a
    /// security assertion), and one body element.
    public init(addressing: WSAddressing, extraHeaders: [XElement] = [], payload: XElement) {
        self.init(headers: addressing.headers + extraHeaders, body: [payload])
    }

    public var addressing: WSAddressing? {
        try? WSAddressing(headers: headers)
    }
}
