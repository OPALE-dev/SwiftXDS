import Foundation
import Testing
import SwiftXDS
@testable import SwiftXDSSOAP

/// Lifetime of the lazy MTOM byte sequence (#230): an early stop releases the file and the
/// producer, a fast producer is held to a bounded buffer.
@Suite struct MTOMStreamTests {
    actor Flag {
        private(set) var value = false
        func set() { value = true }
    }

    func envelope() -> SOAPEnvelope { SOAPEnvelope(body: [XElement(XName("urn:x", "p"))]) }

    func eventually(_ seconds: Double = 5, _ condition: @Sendable () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await condition()
    }

    @Test func anEarlyStopCancelsTheProducer() async throws {
        let ended = Flag()
        let endless: @Sendable (ByteSink) async throws -> Void = { sink in
            defer { Task { await ended.set() } }
            while true { try await sink(Data(repeating: 7, count: 64 << 10)) }
        }
        let message = SOAPMessage(envelope: envelope(), attachments: [MTOMAttachment(contentID: "a@x", body: .producer(endless))])
        do {
            var iterator = try MTOMWriter().bytes(message, chunkSize: 1024, producerBuffer: 128 << 10).makeAsyncIterator()
            for _ in 0..<4 { _ = try await iterator.next() }
        }
        #expect(await eventually { await ended.value })
    }

    @Test func cancellingTheReaderCancelsTheProducer() async throws {
        let ended = Flag()
        let slow: @Sendable (ByteSink) async throws -> Void = { sink in
            defer { Task { await ended.set() } }
            try await sink(Data("first".utf8))
            try await Task.sleep(nanoseconds: 60_000_000_000)
        }
        let message = SOAPMessage(envelope: envelope(), attachments: [MTOMAttachment(contentID: "a@x", body: .producer(slow))])
        let sequence = try MTOMWriter().bytes(message)
        let reader = Task { () -> Int in
            var count = 0
            for try await chunk in sequence { count += chunk.count }
            return count
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        reader.cancel()
        await #expect(throws: CancellationError.self) { _ = try await reader.value }
        #expect(await eventually { await ended.value })
    }

    @Test func anEarlyStopClosesTheFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("swiftxds-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("document.bin")
        try Data(repeating: 1, count: 1 << 20).write(to: url)
        let message = SOAPMessage(envelope: envelope(), attachments: [MTOMAttachment(contentID: "a@x", body: .file(url))])
        weak var resources: MTOMByteSequence.Resources?
        var descriptor: Int32 = -1
        do {
            var iterator = try MTOMWriter().bytes(message, chunkSize: 1024).makeAsyncIterator()
            while iterator.resources.file == nil { _ = try await iterator.next() }
            _ = try await iterator.next()
            descriptor = iterator.resources.file!.fileDescriptor
            resources = iterator.resources
            #expect(fcntl(descriptor, F_GETFD) != -1)
        }
        #expect(resources == nil)
        #expect(fcntl(descriptor, F_GETFD) == -1)
    }

    @Test func aFastProducerKeepsABoundedBuffer() async throws {
        let chunk = 64 << 10, count = 200, buffer = 256 << 10
        let fast: @Sendable (ByteSink) async throws -> Void = { sink in
            for i in 0..<count { try await sink(Data(repeating: UInt8(truncatingIfNeeded: i), count: chunk)) }
        }
        let message = SOAPMessage(envelope: envelope(), attachments: [MTOMAttachment(contentID: "a@x", body: .producer(fast))])
        var iterator = try MTOMWriter().bytes(message, producerBuffer: buffer).makeAsyncIterator()
        var channel: ByteChannel?
        var received = 0
        while let data = try await iterator.next() {
            if channel == nil { channel = iterator.resources.channel }
            if data.count == chunk { received += 1 }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(received == count)
        let peak = try #require(await channel?.peak)
        #expect(peak <= buffer + chunk)
    }

    @Test func aProducerErrorReachesTheReader() async throws {
        struct Broken: Error {}
        let failing: @Sendable (ByteSink) async throws -> Void = { sink in
            try await sink(Data("x".utf8))
            throw Broken()
        }
        let message = SOAPMessage(envelope: envelope(), attachments: [MTOMAttachment(contentID: "a@x", body: .producer(failing))])
        await #expect(throws: Broken.self) {
            for try await _ in try MTOMWriter().bytes(message) {}
        }
    }
}

/// Raw header blocks: checked before sending, original bytes kept on request (#230).
@Suite struct SOAPRawHeaderTests {
    @Test func aMalformedRawHeaderIsRefusedBeforeSending() throws {
        for (raw, index) in [("<a><b></a>", 1), ("<a/><b/>", 1), ("text", 1)] {
            let envelope = SOAPEnvelope(rawHeaders: ["<ok xmlns=\"urn:x\"/>", raw], body: [XElement(XName("urn:x", "p"))])
            #expect {
                _ = try envelope.data()
            } throws: { error in
                guard case SOAPError.malformedRawHeader(let i, _) = error else { return false }
                return i == index
            }
        }
        #expect(throws: Never.self) {
            _ = try SOAPEnvelope(rawHeaders: ["  <ok xmlns=\"urn:x\" a=\"1 > 0\"/>\n"], body: [XElement(XName("urn:x", "p"))]).data()
        }
    }

    @Test func receivedHeadersKeepTheirOriginalBytes() async throws {
        let action = #"<wsa:Action s:mustUnderstand="true">urn:x:a</wsa:Action>"#
        let signed = #"<wsse:Security xmlns:wsse="urn:wsse"><!-- a > b --><saml2:Assertion xmlns:saml2="urn:saml" ID='_a>1'><![CDATA[<not/>]]></saml2:Assertion></wsse:Security>"#
        let empty = #"<x:Flag xmlns:x="urn:x"/>"#
        let xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:wsa="http://www.w3.org/2005/08/addressing">
              <s:Header>
                \(action)
                \(signed)
                \(empty)
              </s:Header>
              <s:Body><p xmlns="urn:x">1</p></s:Body>
            </s:Envelope>
            """
        let kept = try SOAPEnvelope(data: Data(xml.utf8), keepingHeaderBytes: true)
        #expect(kept.headers.count == 3)
        #expect(kept.receivedHeaderBytes.map { String(decoding: $0, as: UTF8.self) } == [action, signed, empty])
        #expect(try SOAPEnvelope(data: Data(xml.utf8)).receivedHeaderBytes.isEmpty)

        var reader = MTOMReader()
        reader.keepsHeaderBytes = true
        let message = try await reader.read(Data(xml.utf8), contentType: "application/soap+xml; charset=UTF-8")
        #expect(message.envelope.receivedHeaderBytes.count == 3)

        let noHeader = #"<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"><s:Body/></s:Envelope>"#
        #expect(try SOAPEnvelope(data: Data(noHeader.utf8), keepingHeaderBytes: true).receivedHeaderBytes.isEmpty)
    }
}
