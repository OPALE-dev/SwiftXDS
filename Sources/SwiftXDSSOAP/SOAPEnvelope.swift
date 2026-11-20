import Foundation
import SwiftXDS

public enum SOAPError: Error, Equatable, Sendable, CustomStringConvertible {
    case notAnEnvelope(XName)
    /// SOAP 1.1 or another envelope version.
    case versionMismatch(String?)
    case missingBody
    case missingHeader(XName)
    case invalidFault(String)
    /// A `rawHeaders` fragment that is not one well-formed element: refused before sending.
    case malformedRawHeader(index: Int, reason: String)

    public var description: String {
        switch self {
        case .notAnEnvelope(let n): "not a SOAP envelope: \(n)"
        case .versionMismatch(let ns): "SOAP 1.2 expected, envelope namespace \(ns ?? "none")"
        case .missingBody: "SOAP envelope without Body"
        case .missingHeader(let n): "missing SOAP header \(n)"
        case .invalidFault(let m): "invalid SOAP fault: \(m)"
        case .malformedRawHeader(let i, let r): "raw header \(i) is not a well-formed element: \(r)"
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
    /// namespace declarations, never rewritten (exclusive canonicalisation stays valid). Each one
    /// is checked before sending (`data()`): a fragment that is not one element is refused.
    public var rawHeaders: [String]
    /// Received envelopes read with `keepingHeaderBytes`: the original bytes of each header block,
    /// in the order of `headers`, as they arrived (for example to verify a signed assertion).
    /// Namespace declarations made on `Envelope` or `Header` are not part of these bytes.
    public var receivedHeaderBytes: [Data] = []
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
        for (index, raw) in rawHeaders.enumerated() {
            do { _ = try XMLReader.parse(raw) } catch {
                throw SOAPError.malformedRawHeader(index: index, reason: String(describing: error))
            }
        }
        return try XMLWriter.data(element)
    }

    /// Reads an envelope; with `keepingHeaderBytes`, also keeps the original bytes of each header
    /// block (`receivedHeaderBytes`).
    public init(data: Data, limits: XMLReader.Limits = .default, keepingHeaderBytes: Bool = false) throws {
        try self.init(element: XMLReader.parse(data, limits: limits))
        if keepingHeaderBytes {
            let bytes = [UInt8](data)
            if let ranges = Self.headerBlockRanges(bytes), ranges.count == headers.count {
                receivedHeaderBytes = ranges.map { Data(bytes[$0]) }
            }
        }
    }

    /// Byte ranges of the children of `Header` in a document the XML reader already accepted;
    /// empty without a header, nil if the bytes cannot be followed.
    static func headerBlockRanges(_ b: [UInt8]) -> [Range<Int>]? {
        func find(_ pattern: String, from: Int) -> Int? {
            let p = Array(pattern.utf8)
            guard from <= b.count - p.count else { return nil }
            var i = from
            while i <= b.count - p.count {
                if b[i] == p[0], Array(b[i..<(i + p.count)]) == p { return i }
                i += 1
            }
            return nil
        }
        func starts(_ prefix: String, at i: Int) -> Bool {
            let p = Array(prefix.utf8)
            return i + p.count <= b.count && Array(b[i..<(i + p.count)]) == p
        }
        var i = 0, depth = 0, inHeader = false, start = 0
        var out: [Range<Int>] = []
        while i < b.count {
            guard b[i] == UInt8(ascii: "<") else { i += 1; continue }
            if starts("<!--", at: i) { guard let e = find("-->", from: i + 4) else { return nil }; i = e + 3; continue }
            if starts("<![CDATA[", at: i) { guard let e = find("]]>", from: i + 9) else { return nil }; i = e + 3; continue }
            if starts("<?", at: i) { guard let e = find("?>", from: i + 2) else { return nil }; i = e + 2; continue }
            if starts("<!", at: i) { return nil }
            var j = i + 1
            var quote: UInt8?
            while j < b.count {
                let c = b[j]
                if let q = quote { if c == q { quote = nil } }
                else if c == UInt8(ascii: "\"") || c == UInt8(ascii: "'") { quote = c }
                else if c == UInt8(ascii: ">") { break }
                j += 1
            }
            guard j < b.count else { return nil }
            let end = j + 1
            if b[i + 1] == UInt8(ascii: "/") {
                if inHeader, depth == 3 { out.append(start..<end) }
                if inHeader, depth == 2 { return out }
                depth -= 1
            } else {
                let empty = b[j - 1] == UInt8(ascii: "/")
                depth += 1
                if depth == 2 {
                    var k = i + 1
                    while k < j, ![UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\n"), UInt8(ascii: "\r"), UInt8(ascii: "/")].contains(b[k]) { k += 1 }
                    let name = String(decoding: b[(i + 1)..<k], as: UTF8.self)
                    guard (name.split(separator: ":").last.map(String.init) ?? name) == "Header", !empty else { return [] }
                    inHeader = true
                } else if depth == 3, inHeader {
                    start = i
                    if empty { out.append(i..<end) }
                }
                if empty { depth -= 1 }
            }
            i = end
        }
        return nil
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
