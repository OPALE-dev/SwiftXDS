import Foundation

public enum MultipartError: Error, Equatable, Sendable, CustomStringConvertible {
    case missingBoundary
    case invalidBoundary
    case malformedHeaders
    /// A boundary delimiter followed by something other than padding and a line break, or `--`.
    case malformedDelimiter
    case headersTooLarge(limit: Int)
    case tooManyParts(limit: Int)
    case partTooLarge(limit: Int)
    case messageTooLarge(limit: Int)
    /// The body ended before the closing delimiter.
    case truncated

    public var description: String {
        switch self {
        case .missingBoundary: "multipart content type without boundary"
        case .invalidBoundary: "invalid multipart boundary"
        case .malformedHeaders: "malformed MIME part headers"
        case .malformedDelimiter: "malformed multipart boundary delimiter line"
        case .headersTooLarge(let n): "MIME part headers larger than \(n) bytes"
        case .tooManyParts(let n): "more than \(n) MIME parts"
        case .partTooLarge(let n): "MIME part larger than \(n) bytes"
        case .messageTooLarge(let n): "multipart message larger than \(n) bytes"
        case .truncated: "multipart message ended before its closing delimiter"
        }
    }
}

/// Bounds applied while reading a multipart message received from another system.
public struct MultipartLimits: Sendable {
    public var maxParts: Int
    public var maxHeaderBytes: Int
    public var maxPartBytes: Int
    public var maxMessageBytes: Int

    public init(maxParts: Int = 10_000, maxHeaderBytes: Int = 16 << 10, maxPartBytes: Int = 4 << 30, maxMessageBytes: Int = 16 << 30) {
        self.maxParts = maxParts
        self.maxHeaderBytes = maxHeaderBytes
        self.maxPartBytes = maxPartBytes
        self.maxMessageBytes = maxMessageBytes
    }

    public static let `default` = MultipartLimits()
}

/// Incremental `multipart/*` reader (RFC 2046 §5.1): feed bytes as they arrive and receive part
/// events. Memory stays bounded by the delimiter length plus the largest header block, whatever the
/// part sizes.
public struct MultipartParser: Sendable {
    public enum Event: Hashable, Sendable {
        case headers(MIMEHeaders)
        case body(Data)
        case end
    }

    enum State { case preamble, afterDelimiter, headers, body, epilogue }

    let delimiter: [UInt8]
    let limits: MultipartLimits
    var buffer: [UInt8]
    var start = 0
    var state = State.preamble
    var parts = 0
    var partBytes = 0
    var total = 0
    /// Where the search for the end of the current header block resumes.
    var headerScan = 0

    public var isComplete: Bool { state == .epilogue }

    public init(boundary: String, limits: MultipartLimits = .default) throws {
        guard (1...70).contains(boundary.utf8.count), !boundary.hasSuffix(" "),
              boundary.utf8.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { throw MultipartError.invalidBoundary }
        delimiter = Array("\r\n--\(boundary)".utf8)
        self.limits = limits
        // The first delimiter may open the body without a preceding line break.
        buffer = [0x0D, 0x0A]
    }

    public init(contentType: MIMEContentType, limits: MultipartLimits = .default) throws {
        guard let boundary = contentType["boundary"] else { throw MultipartError.missingBoundary }
        try self.init(boundary: boundary, limits: limits)
    }

    public mutating func feed(_ data: Data) throws -> [Event] {
        total += data.count
        guard total <= limits.maxMessageBytes else { throw MultipartError.messageTooLarge(limit: limits.maxMessageBytes) }
        if state == .epilogue { return [] }
        buffer.append(contentsOf: data)
        var events: [Event] = []
        loop: while true {
            switch state {
            case .preamble:
                if let i = find(delimiter, from: start) {
                    start = i + delimiter.count
                    state = .afterDelimiter
                } else {
                    start = max(start, buffer.count - delimiter.count + 1)
                    break loop
                }
            case .afterDelimiter:
                // "--" closes the message; otherwise optional transport padding, then CRLF.
                guard buffer.count - start >= 2 else { break loop }
                if buffer[start] == 0x2D, buffer[start + 1] == 0x2D {
                    state = .epilogue
                    start = buffer.count
                    break loop
                }
                var i = start
                while i < buffer.count, buffer[i] == 0x20 || buffer[i] == 0x09 { i += 1 }
                guard buffer.count - i >= 2 else { break loop }
                guard buffer[i] == 0x0D, buffer[i + 1] == 0x0A else { throw MultipartError.malformedDelimiter }
                start = i + 2
                headerScan = start
                parts += 1
                guard parts <= limits.maxParts else { throw MultipartError.tooManyParts(limit: limits.maxParts) }
                state = .headers
            case .headers:
                if buffer.count - start >= 2, buffer[start] == 0x0D, buffer[start + 1] == 0x0A {
                    start += 2
                    events.append(.headers(MIMEHeaders()))
                    partBytes = 0
                    state = .body
                    continue
                }
                guard let end = find([0x0D, 0x0A, 0x0D, 0x0A], from: max(start, headerScan)) else {
                    guard buffer.count - start <= limits.maxHeaderBytes else {
                        throw MultipartError.headersTooLarge(limit: limits.maxHeaderBytes)
                    }
                    headerScan = max(start, buffer.count - 3)
                    break loop
                }
                guard end - start <= limits.maxHeaderBytes else { throw MultipartError.headersTooLarge(limit: limits.maxHeaderBytes) }
                events.append(.headers(try Self.headers(buffer[start..<end])))
                start = end + 4
                partBytes = 0
                state = .body
            case .body:
                if let i = find(delimiter, from: start) {
                    if i > start { try emit(start..<i, into: &events) }
                    events.append(.end)
                    start = i + delimiter.count
                    state = .afterDelimiter
                } else {
                    // Keep a possible partial delimiter at the end of the buffer.
                    let safe = buffer.count - (delimiter.count - 1)
                    if safe > start { try emit(start..<safe, into: &events); start = safe }
                    break loop
                }
            case .epilogue:
                break loop
            }
        }
        compact()
        return events
    }

    /// Call once the input has ended: refuses a message without its closing delimiter.
    public func finish() throws {
        guard state == .epilogue else { throw MultipartError.truncated }
    }

    mutating func emit(_ range: Range<Int>, into events: inout [Event]) throws {
        partBytes += range.count
        guard partBytes <= limits.maxPartBytes else { throw MultipartError.partTooLarge(limit: limits.maxPartBytes) }
        events.append(.body(Data(buffer[range])))
    }

    mutating func compact() {
        if start > 0, start >= buffer.count / 2 || start > 1 << 16 {
            buffer.removeFirst(start)
            headerScan = max(0, headerScan - start)
            start = 0
        }
    }

    /// Bytes held between calls (tests: memory stays bounded whatever the part sizes).
    var bufferedBytes: Int { buffer.count - start }

    func find(_ needle: [UInt8], from: Int) -> Int? {
        let n = needle.count
        guard buffer.count - from >= n else { return nil }
        let first = needle[0]
        var i = from
        let last = buffer.count - n
        return buffer.withUnsafeBufferPointer { b in
            while i <= last {
                if b[i] == first {
                    var j = 1
                    while j < n, b[i + j] == needle[j] { j += 1 }
                    if j == n { return i }
                }
                i += 1
            }
            return nil
        }
    }

    static func headers(_ bytes: ArraySlice<UInt8>) throws -> MIMEHeaders {
        guard let text = String(bytes: bytes, encoding: .utf8) ?? String(bytes: bytes, encoding: .isoLatin1) else {
            throw MultipartError.malformedHeaders
        }
        var headers = MIMEHeaders()
        var current: (String, String)?
        for line in text.components(separatedBy: "\r\n") {
            if line.first == " " || line.first == "\t" {
                // Folded continuation of the previous field.
                guard current != nil else { throw MultipartError.malformedHeaders }
                current!.1 += " " + line.trimmingCharacters(in: .whitespaces)
                continue
            }
            if let c = current { headers.add(c.0, c.1) }
            guard let colon = line.firstIndex(of: ":") else { throw MultipartError.malformedHeaders }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { throw MultipartError.malformedHeaders }
            current = (name, line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }
        if let c = current { headers.add(c.0, c.1) }
        return headers
    }
}
