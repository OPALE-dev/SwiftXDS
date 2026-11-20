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
    /// an HTTP client's back-pressure bounds memory. A producer body waits while `producerBuffer`
    /// bytes are buffered (plus at most one pushed chunk). Dropping the iterator, or cancelling the
    /// task that reads it, closes the open file and cancels the producer.
    public func bytes(_ message: SOAPMessage, chunkSize: Int = 256 << 10, producerBuffer: Int = 1 << 20) throws -> MTOMByteSequence {
        MTOMByteSequence(segments: try segments(message), chunkSize: chunkSize, producerBuffer: max(producerBuffer, 1))
    }
}

public struct MTOMByteSequence: AsyncSequence, Sendable {
    public typealias Element = Data
    let segments: [MTOMWriter.Segment]
    let chunkSize: Int
    let producerBuffer: Int

    public func makeAsyncIterator() -> Iterator {
        Iterator(segments: segments[...], chunkSize: chunkSize, producerBuffer: producerBuffer)
    }

    /// Resources of one iteration, released when the iterator goes away.
    final class Resources: @unchecked Sendable {
        var file: FileHandle?
        var producer: Task<Void, Never>?
        var channel: ByteChannel?

        func release() {
            try? file?.close()
            file = nil
            producer?.cancel()
            producer = nil
            if let channel { Task { await channel.close() } }
            channel = nil
        }

        deinit { release() }
    }

    public struct Iterator: AsyncIteratorProtocol {
        var segments: ArraySlice<MTOMWriter.Segment>
        let chunkSize: Int
        let producerBuffer: Int
        let resources = Resources()

        init(segments: ArraySlice<MTOMWriter.Segment>, chunkSize: Int, producerBuffer: Int) {
            self.segments = segments
            self.chunkSize = chunkSize
            self.producerBuffer = producerBuffer
        }

        public mutating func next() async throws -> Data? {
            do {
                return try await advance()
            } catch {
                resources.release()
                throw error
            }
        }

        private mutating func advance() async throws -> Data? {
            while true {
                try Task.checkCancellation()
                if let handle = resources.file {
                    if let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty { return chunk }
                    try? handle.close()
                    resources.file = nil
                    continue
                }
                if let channel = resources.channel {
                    if let chunk = try await channel.next() { return chunk }
                    resources.channel = nil
                    resources.producer = nil
                    continue
                }
                guard let segment = segments.popFirst() else { return nil }
                switch segment {
                case .bytes(let d): if !d.isEmpty { return d }
                case .file(let url): resources.file = try FileHandle(forReadingFrom: url)
                case .producer(let produce):
                    let channel = ByteChannel(capacity: producerBuffer)
                    resources.channel = channel
                    resources.producer = Task {
                        do {
                            try await produce { try await channel.send($0) }
                            await channel.finish(nil)
                        } catch {
                            await channel.finish(error)
                        }
                    }
                }
            }
        }
    }
}

/// A single-consumer byte buffer between a producer body and the reader of the message: `send`
/// waits while `capacity` bytes are buffered; `close` (the reader went away) fails every waiting
/// and later `send` with `CancellationError`.
actor ByteChannel {
    let capacity: Int
    private var chunks: [Data] = []
    private var buffered = 0
    private var finished = false
    private var failure: Error?
    private var closed = false
    private var consumer: CheckedContinuation<Data?, Error>?
    private var senders: [CheckedContinuation<Void, Error>] = []
    /// Largest number of bytes buffered at once (tests).
    private(set) var peak = 0

    init(capacity: Int) { self.capacity = capacity }

    func send(_ data: Data) async throws {
        guard !data.isEmpty else { return }
        while true {
            if closed { throw CancellationError() }
            if let waiting = consumer {
                consumer = nil
                waiting.resume(returning: data)
                return
            }
            if buffered < capacity { break }
            try await withCheckedThrowingContinuation { senders.append($0) }
        }
        chunks.append(data)
        buffered += data.count
        peak = max(peak, buffered)
    }

    func next() async throws -> Data? {
        if !chunks.isEmpty {
            let chunk = chunks.removeFirst()
            buffered -= chunk.count
            let waiting = senders
            senders = []
            for s in waiting { s.resume() }
            return chunk
        }
        if let failure { throw failure }
        if finished || closed { return nil }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data?, Error>) in
                if closed { c.resume(throwing: CancellationError()) } else { consumer = c }
            }
        } onCancel: {
            Task { await self.close() }
        }
    }

    func finish(_ error: Error?) {
        finished = true
        failure = error
        guard let waiting = consumer else { return }
        consumer = nil
        if let error { waiting.resume(throwing: error) } else { waiting.resume(returning: nil) }
    }

    func close() {
        closed = true
        chunks = []
        buffered = 0
        let waiting = senders
        senders = []
        for s in waiting { s.resume(throwing: CancellationError()) }
        if let c = consumer {
            consumer = nil
            c.resume(throwing: CancellationError())
        }
    }
}
