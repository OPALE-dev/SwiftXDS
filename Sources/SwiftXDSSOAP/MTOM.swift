import Foundation
import SwiftXDS

/// Receives bytes; a writer pushes a message through it chunk by chunk.
public typealias ByteSink = (Data) async throws -> Void

/// A binary part of an MTOM message, referenced from the envelope by `xop:Include`.
public struct MTOMAttachment: Sendable {
    public enum Body: Sendable {
        case data(Data)
        /// A file, read in chunks when the message is written.
        case file(URL)
        /// Bytes produced on demand, for example from an archive: the closure pushes them to the sink.
        case producer(@Sendable (_ sink: ByteSink) async throws -> Void)
    }

    /// `Content-ID`, without angle brackets.
    public var contentID: String
    public var contentType: String
    public var body: Body

    public init(contentID: String, contentType: String = "application/octet-stream", body: Body) {
        self.contentID = contentID
        self.contentType = contentType
        self.body = body
    }

    public init(contentID: String, contentType: String = "application/octet-stream", data: Data) {
        self.init(contentID: contentID, contentType: contentType, body: .data(data))
    }

    /// A fresh content ID (`<uuid>@swiftxds`).
    public static func newContentID() -> String {
        UUID().uuidString.lowercased() + "@swiftxds"
    }

    /// The bytes, read fully into memory.
    public func data() async throws -> Data {
        switch body {
        case .data(let d): return d
        case .file(let url): return try Data(contentsOf: url)
        case .producer(let produce):
            let box = DataBox()
            try await produce { await box.append($0) }
            return await box.data
        }
    }

    /// Pushes the bytes to `sink`, in chunks of at most `chunkSize` for files.
    public func write(to sink: ByteSink, chunkSize: Int = 1 << 20) async throws {
        switch body {
        case .data(let d): try await sink(d)
        case .file(let url):
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
                try await sink(chunk)
            }
        case .producer(let produce):
            try await produce(sink)
        }
    }
}

actor DataBox {
    var data = Data()
    func append(_ d: Data) { data.append(d) }
}

/// XOP references (`<xop:Include href="cid:…"/>`) inside an envelope.
public enum XOP {
    public static let includeName = XName(Namespace.xop, "Include")

    /// The element holding binary content by reference: `<parent><xop:Include href="cid:id"/></parent>`.
    public static func include(contentID: String) -> XElement {
        XElement(includeName, attributes: [XAttribute(XName("href"), "cid:" + encode(contentID))])
    }

    /// The content ID an element refers to through a child `xop:Include`, if any.
    public static func contentID(in element: XElement) -> String? {
        guard let href = element.element(named: includeName)?.attribute("href") else { return nil }
        return contentID(href: href)
    }

    /// `cid:` URL to content ID (RFC 2392: URL-encoded, without brackets).
    public static func contentID(href: String) -> String? {
        guard href.lowercased().hasPrefix("cid:") else { return nil }
        let raw = String(href.dropFirst(4))
        return raw.removingPercentEncoding ?? raw
    }

    static func encode(_ id: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~@!$&'()*+,;=:")
        return id.addingPercentEncoding(withAllowedCharacters: allowed) ?? id
    }
}

/// A SOAP message with its MTOM attachments, as sent or received over HTTP.
public struct SOAPMessage: Sendable {
    public var envelope: SOAPEnvelope
    public var attachments: [MTOMAttachment]

    public init(envelope: SOAPEnvelope, attachments: [MTOMAttachment] = []) {
        self.envelope = envelope
        self.attachments = attachments
    }

    public func attachment(contentID: String) -> MTOMAttachment? {
        attachments.first { $0.contentID == contentID }
    }

    /// The attachment an element refers to through `xop:Include`.
    public func attachment(referencedBy element: XElement) -> MTOMAttachment? {
        XOP.contentID(in: element).flatMap(attachment(contentID:))
    }
}

/// Writes SOAP 1.2 messages as MTOM/XOP `multipart/related` (W3C MTOM, XOP), the packaging that
/// ITI-41 and ITI-43 require, even without attachments.
public struct MTOMWriter: Sendable {
    public var boundary: String
    public var rootContentID: String
    /// SOAP action, repeated in the `action` parameter as SOAP 1.2 allows.
    public var action: String?

    public init(boundary: String = "MIMEBoundary_" + UUID().uuidString.replacingOccurrences(of: "-", with: ""),
                rootContentID: String = "root.message@swiftxds", action: String? = nil) {
        self.boundary = boundary
        self.rootContentID = rootContentID
        self.action = action
    }

    /// `Content-Type` of the HTTP message.
    public var contentType: MIMEContentType {
        var p = ["type": "application/xop+xml", "boundary": boundary, "start": "<\(rootContentID)>",
                 "start-info": "application/soap+xml"]
        if let action { p["action"] = action }
        return MIMEContentType("multipart/related", parameters: p)
    }

    /// Streams the message to `sink`: root part, then each attachment as it is read.
    public func write(_ message: SOAPMessage, to sink: ByteSink) async throws {
        for segment in try segments(message) {
            switch segment {
            case .bytes(let d): try await sink(d)
            case .file(let url): try await MTOMAttachment(contentID: "", body: .file(url)).write(to: sink)
            case .producer(let produce): try await produce(sink)
            }
        }
    }

    /// The whole message in memory.
    public func data(_ message: SOAPMessage) async throws -> Data {
        let box = DataBox()
        try await write(message) { await box.append($0) }
        return await box.data
    }

    func part(contentType: String, contentID: String) throws -> Data {
        try Self.checkHeader(contentType, "Content-Type")
        try Self.checkHeader(contentID, "Content-ID")
        guard !contentID.contains("<"), !contentID.contains(">") else { throw MTOMError.invalidHeaderValue("Content-ID") }
        return Data("--\(boundary)\r\nContent-Type: \(contentType)\r\nContent-Transfer-Encoding: binary\r\nContent-ID: <\(contentID)>\r\n\r\n".utf8)
    }

    /// Header values come from callers: refuse line breaks and controls (header injection).
    static func checkHeader(_ value: String, _ name: String) throws {
        guard !value.isEmpty, value.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F && $0.value < 0x80 }) else {
            throw MTOMError.invalidHeaderValue(name)
        }
    }

    /// A quoted-string parameter value (RFC 2045): backslash and quote escaped.
    static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

public enum MTOMError: Error, Equatable, Sendable, CustomStringConvertible {
    case unsupportedContentType(String)
    case missingRootPart
    case duplicateContentID(String)
    /// An `xop:Include` names a part the message does not have.
    case unresolvedInclude(String)
    case unsupportedTransferEncoding(String)
    /// A Content-ID, Content-Type or action with line breaks, controls or non-ASCII characters.
    case invalidHeaderValue(String)
    /// The root part is not `application/xop+xml` with `type="application/soap+xml"`.
    case invalidRootPart(String)

    public var description: String {
        switch self {
        case .unsupportedContentType(let t): "unsupported SOAP content type \(t)"
        case .missingRootPart: "MTOM message without its root part"
        case .duplicateContentID(let id): "two MIME parts share Content-ID \(id)"
        case .unresolvedInclude(let id): "xop:Include refers to missing part \(id)"
        case .unsupportedTransferEncoding(let e): "unsupported Content-Transfer-Encoding \(e)"
        case .invalidHeaderValue(let n): "invalid \(n) value"
        case .invalidRootPart(let t): "MTOM root part of type \(t), application/xop+xml with type application/soap+xml expected"
        }
    }
}

/// Where received attachments go. The default keeps them in memory; `MTOMFileStore` writes them to
/// files so that large documents never sit in memory.
public protocol MTOMAttachmentStore: Sendable {
    /// Opens storage for one part and returns the sink of its bytes and a function that closes it.
    func open(headers: MIMEHeaders) async throws -> (sink: ByteSink, finish: @Sendable () async throws -> MTOMAttachment.Body)
}

public struct MTOMMemoryStore: MTOMAttachmentStore {
    public init() {}
    public func open(headers: MIMEHeaders) async throws -> (sink: ByteSink, finish: @Sendable () async throws -> MTOMAttachment.Body) {
        let box = DataBox()
        return ({ await box.append($0) }, { .data(await box.data) })
    }
}

/// Writes each attachment to a new file in `directory`; the caller owns and removes the files.
public struct MTOMFileStore: MTOMAttachmentStore {
    public var directory: URL
    public init(directory: URL) { self.directory = directory }

    public func open(headers: MIMEHeaders) async throws -> (sink: ByteSink, finish: @Sendable () async throws -> MTOMAttachment.Body) {
        let url = directory.appendingPathComponent("swiftxds-" + UUID().uuidString.lowercased() + ".part")
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: url)
        let box = HandleBox(handle)
        return ({ try box.write($0) }, { try box.close(); return .file(url) })
    }
}

final class HandleBox: @unchecked Sendable {
    let handle: FileHandle
    let lock = NSLock()
    init(_ handle: FileHandle) { self.handle = handle }
    func write(_ d: Data) throws { try lock.withLock { try handle.write(contentsOf: d) } }
    func close() throws { try lock.withLock { try handle.close() } }
}

/// Reads SOAP 1.2 messages, MTOM/XOP or plain `application/soap+xml`.
public struct MTOMReader: Sendable {
    public var limits: MultipartLimits
    public var xmlLimits: XMLReader.Limits

    public init(limits: MultipartLimits = .default, xmlLimits: XMLReader.Limits = .default) {
        self.limits = limits
        self.xmlLimits = xmlLimits
    }

    /// MTOM root: `application/xop+xml` with `type="application/soap+xml"` (or no type); a plain
    /// `application/soap+xml` root is tolerated.
    static func checkRoot(_ headers: MIMEHeaders) throws {
        guard let t = headers.contentType else { throw MTOMError.invalidRootPart("none") }
        if t.mediaType == "application/soap+xml" { return }
        guard t.mediaType == "application/xop+xml", (t["type"]?.lowercased() ?? "application/soap+xml") == "application/soap+xml" else {
            throw MTOMError.invalidRootPart(headers["Content-Type"] ?? "")
        }
    }

    public func read(_ data: Data, contentType: String) async throws -> SOAPMessage {
        try await read(chunks: [data].async, contentType: contentType, store: MTOMMemoryStore())
    }

    /// Reads a message as it arrives. The root part is kept in memory (bounded by `xmlLimits`);
    /// attachments go to `store`.
    public func read<S: AsyncSequence>(chunks: S, contentType: String, store: some MTOMAttachmentStore) async throws -> SOAPMessage
    where S.Element == Data {
        guard let type = MIMEContentType(parsing: contentType) else { throw MTOMError.unsupportedContentType(contentType) }
        switch type.mediaType {
        case "application/soap+xml":
            var data = Data()
            for try await chunk in chunks {
                data.append(chunk)
                guard data.count <= xmlLimits.maxBytes else { throw XMLError.tooLarge(limit: xmlLimits.maxBytes) }
            }
            return SOAPMessage(envelope: try SOAPEnvelope(data: data, limits: xmlLimits))
        case "multipart/related":
            break
        default:
            throw MTOMError.unsupportedContentType(type.mediaType)
        }
        var parser = try MultipartParser(contentType: type, limits: limits)
        let start = type["start"].map(MIMEHeaders.unbracket)
        var root: Data?
        var rootHeaders: MIMEHeaders?
        var attachments: [MTOMAttachment] = []
        var seen = Set<String>()
        // Current part: either the root being collected, or an attachment being stored.
        var collecting: Data?
        var current: (headers: MIMEHeaders, sink: ByteSink, finish: @Sendable () async throws -> MTOMAttachment.Body)?

        func isRoot(_ headers: MIMEHeaders) -> Bool {
            if let start { return headers.contentID == start }
            return root == nil && collecting == nil && attachments.isEmpty
        }
        if let t = type["type"]?.lowercased(), t != "application/xop+xml" { throw MTOMError.invalidRootPart(t) }
        do {
            for try await chunk in chunks {
                for event in try parser.feed(chunk) {
                    switch event {
                    case .headers(let headers):
                        if let te = headers["Content-Transfer-Encoding"]?.lowercased(), !["binary", "8bit", "7bit"].contains(te) {
                            throw MTOMError.unsupportedTransferEncoding(te)
                        }
                        if let id = headers.contentID {
                            guard seen.insert(id).inserted else { throw MTOMError.duplicateContentID(id) }
                        }
                        if root == nil, isRoot(headers) {
                            try Self.checkRoot(headers)
                            collecting = Data()
                            rootHeaders = headers
                        } else {
                            let opened = try await store.open(headers: headers)
                            current = (headers, opened.sink, opened.finish)
                        }
                    case .body(let bytes):
                        if collecting != nil {
                            collecting!.append(bytes)
                            guard collecting!.count <= xmlLimits.maxBytes else { throw XMLError.tooLarge(limit: xmlLimits.maxBytes) }
                        } else if let current {
                            try await current.sink(bytes)
                        }
                    case .end:
                        if let c = collecting {
                            root = c
                            collecting = nil
                        } else if let c = current {
                            let body = try await c.finish()
                            attachments.append(MTOMAttachment(
                                contentID: c.headers.contentID ?? "",
                                contentType: c.headers["Content-Type"] ?? "application/octet-stream", body: body))
                            current = nil
                        }
                    }
                }
            }
            try parser.finish()
            guard let root, rootHeaders != nil else { throw MTOMError.missingRootPart }
            let envelope = try SOAPEnvelope(data: root, limits: xmlLimits)
            let message = SOAPMessage(envelope: envelope, attachments: attachments)
            for include in envelope.element.descendants(named: XOP.includeName) {
                guard let id = include.attribute("href").flatMap(XOP.contentID(href:)) else {
                    throw MTOMError.unresolvedInclude(include.attribute("href") ?? "")
                }
                guard message.attachment(contentID: id) != nil else { throw MTOMError.unresolvedInclude(id) }
            }
            return message
        } catch {
            // Do not leave received files behind: close the open part and remove stored files.
            var stored = attachments.map(\.body)
            if let c = current, let body = try? await c.finish() { stored.append(body) }
            for case .file(let url) in stored { try? FileManager.default.removeItem(at: url) }
            throw error
        }
    }
}

extension Array where Element == Data {
    var async: AsyncStream<Data> {
        AsyncStream { continuation in
            for d in self { continuation.yield(d) }
            continuation.finish()
        }
    }
}
