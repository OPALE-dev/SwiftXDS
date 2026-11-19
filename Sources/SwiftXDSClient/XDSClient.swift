import Crypto
import Foundation
import SwiftXDS
import SwiftXDSSOAP

public enum XDSClientError: Error, Sendable, CustomStringConvertible {
    /// Metadata refused before sending; nothing was sent.
    case invalidMetadata([XDSValidationIssue])
    /// ITI-41 sends exactly one document per DocumentEntry: a DocumentEntry without a document,
    /// a document without its DocumentEntry, or two documents for one DocumentEntry.
    case missingDocument(entryUUID: String)
    case unknownDocument(entryUUID: String)
    case duplicateDocument(entryUUID: String)
    /// The peer answered with a SOAP fault.
    case fault(SOAPFault)
    /// The peer answered with an HTTP error and no SOAP fault.
    case http(status: Int, body: String)
    /// The peer answered with something other than SOAP.
    case unexpectedContentType(String)
    /// The response is SOAP but not the expected message.
    case unexpectedResponse(XName?)

    public var description: String {
        switch self {
        case .invalidMetadata(let issues): "metadata refused before sending: " + issues.map(\.description).joined(separator: "; ")
        case .missingDocument(let id): "no document given for DocumentEntry \(id)"
        case .unknownDocument(let id): "document \(id) has no DocumentEntry"
        case .duplicateDocument(let id): "two documents given for DocumentEntry \(id)"
        case .fault(let f): f.description
        case .http(let s, let b): "HTTP \(s)" + (b.isEmpty ? "" : ": " + b)
        case .unexpectedContentType(let t): "unexpected response content type '\(t)'"
        case .unexpectedResponse(let n): "unexpected response \(n.map(\.description) ?? "without body")"
        }
    }
}

/// Header blocks added to every request, for example a security assertion (VIHF for the French
/// DMP). `raw` blocks are written verbatim, which keeps a signature valid.
public struct XDSRequestHeaders: Sendable {
    public var elements: [XElement]
    public var raw: [String]

    public init(elements: [XElement] = [], raw: [String] = []) {
        self.elements = elements
        self.raw = raw
    }
}

/// Sends a SOAP request and returns the response; `XDSHTTPTransport` is the HTTP one, tests may
/// provide another.
public protocol XDSTransport: Sendable {
    func send(_ request: SOAPMessage, transaction: XDSTransaction, to endpoint: URL) async throws -> SOAPMessage
}

/// Entry point for the XDS.b transactions of SwiftXDS.
public struct XDSClient: Sendable {
    public var transport: any XDSTransport
    /// Called for each request: security headers that depend on the transaction or expire.
    public var headers: @Sendable (XDSTransaction) async throws -> XDSRequestHeaders
    /// Refuse locally metadata that the registry would refuse (default `true`).
    public var validatesMetadata: Bool

    public init(transport: any XDSTransport, validatesMetadata: Bool = true,
                headers: @escaping @Sendable (XDSTransaction) async throws -> XDSRequestHeaders = { _ in XDSRequestHeaders() }) {
        self.transport = transport
        self.validatesMetadata = validatesMetadata
        self.headers = headers
    }

    /// Sends one request and returns the response payload, faults raised as `XDSClientError.fault`.
    public func call(_ transaction: XDSTransaction, to endpoint: URL, payload: XElement,
                     attachments: [MTOMAttachment] = []) async throws -> SOAPMessage {
        let extra = try await headers(transaction)
        let addressing = WSAddressing.request(action: transaction.requestAction, to: endpoint.absoluteString)
        let envelope = SOAPEnvelope(headers: addressing.headers + extra.elements, rawHeaders: extra.raw, body: [payload])
        let response = try await transport.send(SOAPMessage(envelope: envelope, attachments: attachments),
                                                transaction: transaction, to: endpoint)
        if let fault = try response.envelope.fault() { throw XDSClientError.fault(fault) }
        return response
    }
}

public enum XDSHash {
    /// `DocumentEntry.hash`: SHA-1 of the document, lower-case hexadecimal.
    public static func sha1(_ data: Data) -> String {
        Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// SHA-1 and size of a document body, read in chunks.
    public static func digest(of body: MTOMAttachment.Body) async throws -> (hash: String, size: Int64) {
        let box = HashBox()
        try await MTOMAttachment(contentID: "x", body: body).write { await box.update($0) }
        return await box.result()
    }
}

actor HashBox {
    var hasher = Insecure.SHA1()
    var size: Int64 = 0
    func update(_ d: Data) { hasher.update(data: d); size += Int64(d.count) }
    func result() -> (hash: String, size: Int64) {
        (hasher.finalize().map { String(format: "%02x", $0) }.joined(), size)
    }
}

extension XDSDocumentEntry {
    /// Sets `hash` and `size` from the document (optional for a Document Source, which lets the
    /// repository compute them; a repository checks them when present).
    public mutating func setHashAndSize(of body: MTOMAttachment.Body) async throws {
        let d = try await XDSHash.digest(of: body)
        hash = d.hash
        size = d.size
    }
}
