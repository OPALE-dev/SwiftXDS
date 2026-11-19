import AsyncHTTPClient
import Foundation
import NIOCore
import NIOFoundationCompat
import SwiftXDS
import SwiftXDSSOAP

/// SOAP 1.2 over HTTP with AsyncHTTPClient: MTOM for ITI-41 and ITI-43, plain SOAP for the
/// others. TLS (including client certificates) is the `HTTPClient`'s configuration.
public struct XDSHTTPTransport: XDSTransport {
    public var client: HTTPClient
    /// Deadline of the whole exchange, sending the documents included (AsyncHTTPClient's
    /// `execute(_:timeout:)`): not an inactivity delay. Size it for the largest upload; inactivity
    /// limits are the `HTTPClient.Configuration.Timeout` (connect, read) of the client.
    public var timeout: TimeAmount
    public var limits: MultipartLimits
    public var xmlLimits: XMLReader.Limits
    /// Where documents of responses go (ITI-43). Default: memory.
    public var store: any MTOMAttachmentStore
    /// Additional HTTP headers (for example an API gateway key).
    public var httpHeaders: [(String, String)]

    public init(client: HTTPClient, timeout: TimeAmount = .seconds(120), limits: MultipartLimits = .default,
                xmlLimits: XMLReader.Limits = .default, store: any MTOMAttachmentStore = MTOMMemoryStore(),
                httpHeaders: [(String, String)] = []) {
        self.client = client
        self.timeout = timeout
        self.limits = limits
        self.xmlLimits = xmlLimits
        self.store = store
        self.httpHeaders = httpHeaders
    }

    public func send(_ message: SOAPMessage, transaction: XDSTransaction, to endpoint: URL) async throws -> SOAPMessage {
        var request = HTTPClientRequest(url: endpoint.absoluteString)
        request.method = .POST
        for (name, value) in httpHeaders { request.headers.add(name: name, value: value) }
        if transaction.usesMTOM || !message.attachments.isEmpty {
            let writer = MTOMWriter(action: transaction.requestAction)
            request.headers.replaceOrAdd(name: "Content-Type", value: writer.contentType.description)
            let bytes = try writer.bytes(message).map { ByteBuffer(data: $0) }
            // A known length avoids chunked transfer, which some registries refuse.
            let length = try writer.length(of: message).map { HTTPClientRequest.Body.Length.known(Int64($0)) } ?? .unknown
            request.body = .stream(bytes, length: length)
        } else {
            let type = MIMEContentType("application/soap+xml", parameters: ["charset": "UTF-8", "action": transaction.requestAction])
            request.headers.replaceOrAdd(name: "Content-Type", value: type.description)
            request.body = .bytes(ByteBuffer(data: try message.envelope.data()))
        }

        let response = try await client.execute(request, timeout: timeout)
        let status = Int(response.status.code)
        let contentType = response.headers.first(name: "Content-Type") ?? ""
        let media = MIMEContentType(parsing: contentType)?.mediaType
        guard media == "application/soap+xml" || media == "multipart/related" else {
            // Not SOAP: keep a short, printable excerpt for the error.
            var excerpt = Data()
            for try await chunk in response.body {
                excerpt.append(Data(buffer: chunk))
                if excerpt.count >= 512 { break }
            }
            let text = String(decoding: excerpt.prefix(512), as: UTF8.self).filter { !$0.isNewline }
            if !(200..<300).contains(status) { throw XDSClientError.http(status: status, body: text) }
            throw XDSClientError.unexpectedContentType(contentType)
        }
        let chunks = response.body.map { Data(buffer: $0) }
        let reply = try await MTOMReader(limits: limits, xmlLimits: xmlLimits).read(chunks: chunks, contentType: contentType, store: store)
        if let fault = try reply.envelope.fault() { throw XDSClientError.fault(fault) }
        guard (200..<300).contains(status) else { throw XDSClientError.http(status: status, body: "") }
        return reply
    }
}
