import Foundation

extension MTOMWriter {
    enum Segment: Sendable {
        case bytes(Data)
        case file(URL)
        case producer(@Sendable (_ sink: ByteSink) async throws -> Void)
    }

    func segments(_ message: SOAPMessage) throws -> [Segment] {
        var rootType = "application/xop+xml; charset=UTF-8; type=\"application/soap+xml\""
        if let action {
            try Self.checkHeader(action, "action")
            rootType += "; action=" + Self.quoted(action)
        }
        var out: [Segment] = [.bytes(try part(contentType: rootType, contentID: rootContentID) + (try message.envelope.data()))]
        for a in message.attachments {
            out.append(.bytes(Data("\r\n".utf8) + (try part(contentType: a.contentType, contentID: a.contentID))))
            switch a.body {
            case .data(let d): out.append(.bytes(d))
            case .file(let url): out.append(.file(url))
            case .producer(let p): out.append(.producer(p))
            }
        }
        out.append(.bytes(Data("\r\n--\(boundary)--\r\n".utf8)))
        return out
    }

    /// Size of the written message, when every attachment has a known size (data or file).
    public func length(of message: SOAPMessage) throws -> Int? {
        var total = 0
        for s in try segments(message) {
            switch s {
            case .bytes(let d): total += d.count
            case .file(let url):
                guard let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber else { return nil }
                total += size.intValue
            case .producer: return nil
            }
        }
        return total
    }

    /// The message as a lazy byte sequence: files are read only as the consumer asks for more, so
    /// an HTTP client's back-pressure bounds memory. Producer bodies are buffered as they push.
    public func bytes(_ message: SOAPMessage, chunkSize: Int = 256 << 10) throws -> MTOMByteSequence {
        MTOMByteSequence(segments: try segments(message), chunkSize: chunkSize)
    }
}

public struct MTOMByteSequence: AsyncSequence, Sendable {
    public typealias Element = Data
    let segments: [MTOMWriter.Segment]
    let chunkSize: Int

    public func makeAsyncIterator() -> Iterator {
        Iterator(segments: segments[...], chunkSize: chunkSize)
    }

    public struct Iterator: AsyncIteratorProtocol {
        var segments: ArraySlice<MTOMWriter.Segment>
        let chunkSize: Int
        var file: FileHandle?
        var pushed: AsyncThrowingStream<Data, Error>.Iterator?

        public mutating func next() async throws -> Data? {
            while true {
                if let handle = file {
                    if let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty { return chunk }
                    try? handle.close()
                    file = nil
                    continue
                }
                if pushed != nil {
                    if let chunk = try await pushed!.next() { return chunk }
                    pushed = nil
                    continue
                }
                guard let segment = segments.popFirst() else { return nil }
                switch segment {
                case .bytes(let d): if !d.isEmpty { return d }
                case .file(let url): file = try FileHandle(forReadingFrom: url)
                case .producer(let produce):
                    let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
                    Task {
                        do {
                            try await produce { continuation.yield($0) }
                            continuation.finish()
                        } catch {
                            continuation.finish(throwing: error)
                        }
                    }
                    pushed = stream.makeAsyncIterator()
                }
            }
        }
    }
}
