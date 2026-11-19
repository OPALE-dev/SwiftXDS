import Foundation
import Testing
import SwiftXDS
@testable import SwiftXDSSOAP

/// Text with LF line ends sent as CRLF; `<CRLF>` stands for a line break inside a body.
private func crlf(_ s: String) -> Data {
    Data(s.replacingOccurrences(of: "\n", with: "\r\n").replacingOccurrences(of: "<CRLF>", with: "\r\n").utf8)
}

private func events(_ parser: inout MultipartParser, _ data: Data, chunk: Int) throws -> [MultipartParser.Event] {
    var out: [MultipartParser.Event] = []
    var i = data.startIndex
    while i < data.endIndex {
        let j = data.index(i, offsetBy: chunk, limitedBy: data.endIndex) ?? data.endIndex
        out += try parser.feed(data[i..<j])
        i = j
    }
    try parser.finish()
    return out
}

/// Parts as (headers, joined body).
private func parts(_ events: [MultipartParser.Event]) -> [(MIMEHeaders, Data)] {
    var out: [(MIMEHeaders, Data)] = []
    for e in events {
        switch e {
        case .headers(let h): out.append((h, Data()))
        case .body(let d): out[out.count - 1].1.append(d)
        case .end: break
        }
    }
    return out
}

@Suite struct MultipartParserTests {
    let message = crlf("""
    preamble to ignore
    --b1
    Content-Type: text/plain
    Content-ID:
     <first@x>

    one
    --b1 \t

    two, no headers, with <CRLF>--b and --b1x inside
    --b1--
    epilogue
    """)

    @Test(arguments: [1, 2, 3, 7, 64, 4096])
    func partsAreTheSameWhateverTheChunking(chunk: Int) throws {
        var parser = try MultipartParser(boundary: "b1")
        let p = parts(try events(&parser, message, chunk: chunk))
        #expect(p.count == 2)
        #expect(p[0].0.contentID == "first@x")
        #expect(p[0].0["content-type"] == "text/plain")
        #expect(p[0].1 == Data("one".utf8))
        #expect(p[1].0.fields.isEmpty)
        #expect(p[1].1 == Data("two, no headers, with \r\n--b and --b1x inside".utf8))
        #expect(parser.isComplete)
    }

    @Test func bodyMayStartWithTheDelimiter() throws {
        var parser = try MultipartParser(boundary: "z")
        let p = parts(try events(&parser, crlf("--z\nA: 1\n\nx\n--z--"), chunk: 5))
        #expect(p.map { $0.1 } == [Data("x".utf8)])
    }

    @Test func truncatedMessageIsRefused() throws {
        var parser = try MultipartParser(boundary: "z")
        _ = try parser.feed(crlf("--z\n\nunfinished"))
        #expect(throws: MultipartError.truncated) { try parser.finish() }
    }

    @Test func limitsAreEnforced() throws {
        var many = try MultipartParser(boundary: "z", limits: .init(maxParts: 1))
        #expect(throws: MultipartError.tooManyParts(limit: 1)) { _ = try many.feed(crlf("--z\n\na\n--z\n\nb\n--z--")) }

        var big = try MultipartParser(boundary: "z", limits: .init(maxPartBytes: 4))
        #expect(throws: MultipartError.partTooLarge(limit: 4)) { _ = try big.feed(crlf("--z\n\n0123456789\n--z--")) }

        var headers = try MultipartParser(boundary: "z", limits: .init(maxHeaderBytes: 8))
        #expect(throws: MultipartError.headersTooLarge(limit: 8)) { _ = try headers.feed(crlf("--z\nX-Long: 0123456789\n\n")) }

        var total = try MultipartParser(boundary: "z", limits: .init(maxMessageBytes: 4))
        #expect(throws: MultipartError.messageTooLarge(limit: 4)) { _ = try total.feed(Data("0123456789".utf8)) }
    }

    @Test func boundaryIsValidated() {
        #expect(throws: MultipartError.invalidBoundary) { try MultipartParser(boundary: "") }
        #expect(throws: MultipartError.invalidBoundary) { try MultipartParser(boundary: String(repeating: "x", count: 71)) }
        #expect(throws: MultipartError.missingBoundary) { try MultipartParser(contentType: MIMEContentType("multipart/related")) }
    }

    @Test func bufferStaysBoundedOnLargeParts() throws {
        var parser = try MultipartParser(boundary: "z")
        _ = try parser.feed(crlf("--z\n\n"))
        let chunk = Data(repeating: 0x41, count: 64 << 10)
        var bytes = 0
        for _ in 0..<64 {
            for case .body(let d) in try parser.feed(chunk) { bytes += d.count }
            #expect(parser.bufferedBytes < 2 * chunk.count)
        }
        #expect(bytes > 63 * chunk.count)
    }

    @Test func malformedDelimiterLineIsRefused() throws {
        var parser = try MultipartParser(boundary: "z")
        #expect(throws: MultipartError.malformedDelimiter) { _ = try parser.feed(crlf("--z garbage\n\nx\n--z--")) }
    }

    @Test func malformedHeadersAreRefused() throws {
        var parser = try MultipartParser(boundary: "z")
        #expect(throws: MultipartError.malformedHeaders) { _ = try parser.feed(crlf("--z\nno colon here\n\nx\n--z--")) }
    }
}

@Suite struct MTOMTests {
    func request(documentID: String) -> SOAPEnvelope {
        let document = XElement(XName(Namespace.xdsb, "Document"), attributes: [XAttribute(XName("id"), "Document01")],
                                elements: [XOP.include(contentID: documentID)])
        let payload = XElement(XName(Namespace.xdsb, "ProvideAndRegisterDocumentSetRequest"), elements: [document])
        return SOAPEnvelope(addressing: .request(action: "urn:ihe:iti:2007:ProvideAndRegisterDocumentSet-b", to: "https://r.example.invalid"),
                            payload: payload)
    }

    /// Bytes that look like delimiters and line breaks, to catch boundary handling errors.
    let binary = Data((0..<70_000).map { UInt8(truncatingIfNeeded: $0 &* 31) }) + Data("\r\n--MIMEBoundary_\r\n".utf8)

    @Test func writtenMessageReadsBack() async throws {
        let id = "1.urn:uuid:b1a9c4f2@example.invalid"
        let message = SOAPMessage(envelope: request(documentID: id),
                                  attachments: [MTOMAttachment(contentID: id, contentType: "application/dicom", data: binary)])
        let writer = MTOMWriter(action: "urn:ihe:iti:2007:ProvideAndRegisterDocumentSet-b")
        let data = try await writer.data(message)
        let text = String(decoding: data.prefix(400), as: UTF8.self)
        #expect(text.hasPrefix("--\(writer.boundary)\r\nContent-Type: application/xop+xml; charset=UTF-8; type=\"application/soap+xml\""))
        #expect(data.range(of: Data("href=\"cid:1.urn:uuid:b1a9c4f2@example.invalid\"".utf8)) != nil)

        let read = try await MTOMReader().read(data, contentType: writer.contentType.description)
        #expect(read.envelope == message.envelope)
        let document = try #require(read.envelope.payload?.element(named: XName(Namespace.xdsb, "Document")))
        let attachment = try #require(read.attachment(referencedBy: document))
        #expect(attachment.contentType == "application/dicom")
        #expect(try await attachment.data() == binary)
    }

    @Test func messageWithoutAttachmentsIsStillMTOM() async throws {
        let writer = MTOMWriter()
        let message = SOAPMessage(envelope: SOAPEnvelope(body: [XElement(XName(Namespace.xdsb, "RetrieveDocumentSetRequest"))]))
        let data = try await writer.data(message)
        #expect(writer.contentType.mediaType == "multipart/related")
        #expect(writer.contentType["start-info"] == "application/soap+xml")
        let read = try await MTOMReader().read(data, contentType: writer.contentType.description)
        #expect(read.envelope == message.envelope)
        #expect(read.attachments.isEmpty)
    }

    @Test func fileAndProducerBodiesAreStreamed() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("swiftxds-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.bin")
        try binary.write(to: source)
        let chunks = [Data("produced ".utf8), Data("in two chunks".utf8)]
        let envelope = SOAPEnvelope(body: [XElement(XName("urn:x", "r"), elements: [
            XElement(XName("urn:x", "a"), elements: [XOP.include(contentID: "a@x")]),
            XElement(XName("urn:x", "b"), elements: [XOP.include(contentID: "b@x")]),
        ])])
        let message = SOAPMessage(envelope: envelope, attachments: [
            MTOMAttachment(contentID: "a@x", body: .file(source)),
            MTOMAttachment(contentID: "b@x", contentType: "text/plain", body: .producer({ sink in
                for c in chunks { try await sink(c) }
            })),
        ])
        let writer = MTOMWriter()
        var sent: [Data] = []
        let box = DataBox()
        try await writer.write(message) { chunk in await box.append(chunk) }
        let data = await box.data
        // Feed the reader in small pieces, attachments stored as files.
        var i = 0
        while i < data.count { sent.append(data[i..<min(i + 997, data.count)]); i += 997 }
        let received = directory.appendingPathComponent("received")
        try FileManager.default.createDirectory(at: received, withIntermediateDirectories: true)
        let read = try await MTOMReader().read(chunks: sent.async, contentType: writer.contentType.description,
                                               store: MTOMFileStore(directory: received))
        #expect(read.attachments.count == 2)
        guard case .file(let a) = read.attachment(contentID: "a@x")?.body else { Issue.record("not a file"); return }
        #expect(try Data(contentsOf: a) == binary)
        #expect(try await read.attachment(contentID: "b@x")?.data() == Data("produced in two chunks".utf8))
    }

    @Test func plainSOAPIsAccepted() async throws {
        let envelope = SOAPEnvelope(body: [XElement(XName(Namespace.rs, "RegistryResponse"))])
        let read = try await MTOMReader().read(try envelope.data(), contentType: "application/soap+xml; charset=UTF-8")
        #expect(read.envelope == envelope)
    }

    @Test func otherContentTypesAreRefused() async throws {
        await #expect(throws: MTOMError.unsupportedContentType("text/html")) {
            try await MTOMReader().read(Data("<html/>".utf8), contentType: "text/html")
        }
    }

    @Test func unresolvedIncludeIsRefused() async throws {
        let message = SOAPMessage(envelope: request(documentID: "missing@x"))
        let writer = MTOMWriter()
        let data = try await writer.data(message)
        await #expect(throws: MTOMError.unresolvedInclude("missing@x")) {
            try await MTOMReader().read(data, contentType: writer.contentType.description)
        }
    }

    @Test func duplicateContentIDIsRefused() async throws {
        let message = SOAPMessage(envelope: request(documentID: "d@x"), attachments: [
            MTOMAttachment(contentID: "d@x", data: Data("1".utf8)), MTOMAttachment(contentID: "d@x", data: Data("2".utf8)),
        ])
        let writer = MTOMWriter()
        let data = try await writer.data(message)
        await #expect(throws: MTOMError.duplicateContentID("d@x")) {
            try await MTOMReader().read(data, contentType: writer.contentType.description)
        }
    }

    @Test func rootIsFoundByStartParameter() async throws {
        // Root part second, as the start parameter allows.
        let envelope = try SOAPEnvelope(body: [XElement(XName("urn:x", "r"), elements: [XOP.include(contentID: "att")])]).data()
        var body = crlf("--q\nContent-ID: <att>\nContent-Type: text/plain\n\nATT\n--q\nContent-ID: <main>\nContent-Type: application/xop+xml; type=\"application/soap+xml\"\n\n")
        body += envelope + crlf("\n--q--\n")
        let read = try await MTOMReader().read(body, contentType: #"multipart/related; boundary=q; type="application/xop+xml"; start="<main>""#)
        #expect(try await read.attachment(contentID: "att")?.data() == Data("ATT".utf8))
    }

    @Test func base64TransferEncodingIsRefused() async throws {
        let body = crlf("--q\nContent-Transfer-Encoding: base64\n\nAAAA\n--q--")
        await #expect(throws: MTOMError.unsupportedTransferEncoding("base64")) {
            try await MTOMReader().read(body, contentType: "multipart/related; boundary=q")
        }
    }

    @Test func contentIDsAreURLEncodedInHrefs() {
        let include = XOP.include(contentID: "a b/c@x")
        #expect(include.attribute("href") == "cid:a%20b%2Fc@x")
        #expect(XOP.contentID(href: "CID:a%20b%2Fc@x") == "a b/c@x")
        #expect(XOP.contentID(href: "http://x") == nil)
    }

    @Test func headerInjectionIsRefused() async throws {
        let envelope = SOAPEnvelope(body: [XElement(XName("urn:x", "r"))])
        let injected = SOAPMessage(envelope: envelope, attachments: [MTOMAttachment(contentID: "a@x\r\nX-Injected: 1", data: Data())])
        await #expect(throws: MTOMError.invalidHeaderValue("Content-ID")) { try await MTOMWriter().data(injected) }
        let badType = SOAPMessage(envelope: envelope, attachments: [MTOMAttachment(contentID: "a@x", contentType: "text/plain\nX: 1", data: Data())])
        await #expect(throws: MTOMError.invalidHeaderValue("Content-Type")) { try await MTOMWriter().data(badType) }
        await #expect(throws: MTOMError.invalidHeaderValue("action")) {
            try await MTOMWriter(action: "urn:a\r\nX: 1").data(SOAPMessage(envelope: envelope))
        }
        // Quotes and backslashes in the action are escaped, not interpreted.
        let writer = MTOMWriter(action: #"urn:a"b\c"#)
        let data = try await writer.data(SOAPMessage(envelope: envelope))
        #expect(data.range(of: Data(#"action="urn:a\"b\\c""#.utf8)) != nil)
        #expect(MIMEContentType(parsing: writer.contentType.description)?["action"] == #"urn:a"b\c"#)
    }

    @Test func storedFilesAreRemovedWhenReadingFails() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("swiftxds-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let message = SOAPMessage(envelope: request(documentID: "a@x"), attachments: [
            MTOMAttachment(contentID: "a@x", data: binary), MTOMAttachment(contentID: "b@x", data: binary),
        ])
        let writer = MTOMWriter()
        let data = try await writer.data(message)
        let truncated = data.prefix(data.count - 5_000)
        await #expect(throws: MultipartError.truncated) {
            try await MTOMReader().read(chunks: [truncated].async, contentType: writer.contentType.description,
                                        store: MTOMFileStore(directory: directory))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test func rootPartMustBeSOAP() async throws {
        let body = crlf("--q\nContent-Type: text/html\n\n<html/>\n--q--")
        await #expect(throws: MTOMError.invalidRootPart("text/html")) {
            try await MTOMReader().read(body, contentType: "multipart/related; boundary=q")
        }
        await #expect(throws: MTOMError.invalidRootPart("text/xml")) {
            try await MTOMReader().read(body, contentType: #"multipart/related; boundary=q; type="text/xml""#)
        }
    }

    @Test func lengthIsKnownForDataAndFiles() async throws {
        let message = SOAPMessage(envelope: request(documentID: "a@x"), attachments: [MTOMAttachment(contentID: "a@x", data: binary)])
        let writer = MTOMWriter()
        let data = try await writer.data(message)
        #expect(try writer.length(of: message) == data.count)
        var lazy = Data()
        for try await chunk in try writer.bytes(message, chunkSize: 1000) { lazy.append(chunk) }
        #expect(lazy == data)
        let pushed = SOAPMessage(envelope: message.envelope, attachments: [MTOMAttachment(contentID: "a@x", body: .producer({ try await $0(Data("x".utf8)) }))])
        #expect(try writer.length(of: pushed) == nil)
    }
}
