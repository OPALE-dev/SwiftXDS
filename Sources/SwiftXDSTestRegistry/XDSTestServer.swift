import Foundation
import NIOCore
import NIOFoundationCompat
import NIOHTTP1
import NIOPosix
import SwiftXDS
import SwiftXDSSOAP

/// A small HTTP/1.1 server for tests and simulators: an `XDSTestRegistry` (every transaction is
/// posted to the same URL and dispatched by its WS-Addressing action), or any responder. Plain
/// HTTP; put a TLS proxy in front when needed.
public final class XDSTestServer: Sendable {
    /// What the server answers: status, content type and body.
    public typealias Response = (status: HTTPResponseStatus, contentType: String, body: Data)
    public typealias Responder = @Sendable (_ head: HTTPRequestHead, _ body: Data) async -> Response

    public struct Limits: Sendable {
        /// Largest request body; a larger one is answered 413.
        public var maxRequestBytes: Int
        /// Connections served at once; others are closed on arrival.
        public var maxConnections: Int
        public var multipart: MultipartLimits
        public var xml: XMLReader.Limits

        public init(maxRequestBytes: Int = 32 << 20, maxConnections: Int = 64,
                    multipart: MultipartLimits = .default, xml: XMLReader.Limits = .default) {
            self.maxRequestBytes = maxRequestBytes
            self.maxConnections = maxConnections
            self.multipart = multipart
            self.xml = xml
        }

        public static let `default` = Limits()
    }

    /// The registry served, when started with one.
    public let registry: XDSTestRegistry?
    public let host: String
    public let port: Int
    let channel: NIOAsyncChannel<NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>, Never>
    let serving: Task<Void, Never>
    let state: ServerState

    /// The endpoint for every transaction.
    public var url: URL { URL(string: "http://\(host):\(port)/xds")! }

    /// Connection and protocol errors seen so far (the server keeps serving).
    public var errors: [String] { state.errors }

    init(registry: XDSTestRegistry?, host: String, port: Int,
         channel: NIOAsyncChannel<NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>, Never>,
         serving: Task<Void, Never>, state: ServerState) {
        self.registry = registry
        self.host = host
        self.port = port
        self.channel = channel
        self.serving = serving
        self.state = state
    }

    /// Serves a registry; `port: 0` picks a free port.
    public static func start(registry: XDSTestRegistry, host: String = "127.0.0.1", port: Int = 0,
                             limits: Limits = .default) async throws -> XDSTestServer {
        try await start(host: host, port: port, limits: limits, registry: registry) { head, body in
            await respond(head, body, registry: registry, limits: limits)
        }
    }

    /// Serves any responder, for example to simulate a failing peer.
    public static func start(host: String = "127.0.0.1", port: Int = 0, limits: Limits = .default,
                             responder: @escaping Responder) async throws -> XDSTestServer {
        try await start(host: host, port: port, limits: limits, registry: nil, responder: responder)
    }

    static func start(host: String, port: Int, limits: Limits, registry: XDSTestRegistry?,
                      responder: @escaping Responder) async throws -> XDSTestServer {
        let state = ServerState()
        let channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .bind(host: host, port: port) { child in
                child.eventLoop.makeCompletedFuture {
                    try child.pipeline.syncOperations.configureHTTPServerPipeline()
                    return try NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>(wrappingChannelSynchronously: child)
                }
            }
        let bound = channel.channel.localAddress?.port ?? port
        let serving = Task<Void, Never> {
            do {
                try await channel.executeThenClose { inbound in
                    await withTaskGroup(of: Void.self) { group in
                        do {
                            for try await connection in inbound {
                                guard state.open(connection.channel, limit: limits.maxConnections) else {
                                    state.record("connection refused: \(limits.maxConnections) already open")
                                    connection.channel.close(promise: nil)
                                    continue
                                }
                                group.addTask {
                                    await serve(connection, limits: limits, state: state, responder: responder)
                                    state.closed(connection.channel)
                                }
                            }
                        } catch {
                            state.record("accept: \(error)")
                        }
                    }
                }
            } catch {
                state.record("listen: \(error)")
            }
        }
        return XDSTestServer(registry: registry, host: host, port: bound, channel: channel, serving: serving, state: state)
    }

    /// Stops listening, closes the open connections (keep-alive ones too) and waits for them.
    public func stop() async {
        try? await channel.channel.close()
        for child in state.stopping() { try? await child.close() }
        await serving.value
    }

    static func serve(_ connection: NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>,
                      limits: Limits, state: ServerState, responder: Responder) async {
        do {
            try await connection.executeThenClose { inbound, outbound in
                var head: HTTPRequestHead?
                var body = ByteBuffer()
                var tooLarge = false
                for try await part in inbound {
                    switch part {
                    case .head(let h):
                        head = h
                        body.clear()
                        tooLarge = false
                    case .body(var chunk):
                        if tooLarge || body.readableBytes + chunk.readableBytes > limits.maxRequestBytes {
                            tooLarge = true
                            body.clear()
                        } else {
                            body.writeBuffer(&chunk)
                        }
                    case .end:
                        guard let request = head else { continue }
                        let response = tooLarge
                            ? (HTTPResponseStatus.payloadTooLarge, "text/plain", Data("request larger than \(limits.maxRequestBytes) bytes".utf8))
                            : await responder(request, Data(buffer: body))
                        var headers = HTTPHeaders()
                        headers.add(name: "Content-Type", value: response.1)
                        headers.add(name: "Content-Length", value: String(response.2.count))
                        try await outbound.write(.head(HTTPResponseHead(version: request.version, status: response.0, headers: headers)))
                        try await outbound.write(.body(.byteBuffer(ByteBuffer(data: response.2))))
                        try await outbound.write(.end(nil))
                    }
                }
            }
        } catch {
            if !state.isStopping { state.record("connection: \(error)") }
        }
    }

    static func respond(_ head: HTTPRequestHead, _ body: Data, registry: XDSTestRegistry, limits: Limits) async -> Response {
        guard head.method == .POST else { return (.methodNotAllowed, "text/plain", Data("POST a SOAP 1.2 request".utf8)) }
        let contentType = head.headers.first(name: "Content-Type") ?? ""
        let request: SOAPMessage
        do {
            request = try await MTOMReader(limits: limits.multipart, xmlLimits: limits.xml).read(body, contentType: contentType)
        } catch {
            let fault = SOAPFault(code: .sender, reason: "Unreadable request: \(error)")
            return await soap(SOAPMessage(envelope: SOAPEnvelope(addressing: WSAddressing(action: SOAPFault.faultAction), payload: fault.element)))
        }
        return await soap(await registry.handle(request))
    }

    /// SOAP 1.2 HTTP binding: 400 for Sender faults, 500 for the others, MTOM when the response
    /// has attachments or answers ITI-41 and ITI-43.
    static func soap(_ message: SOAPMessage) async -> Response {
        var status = HTTPResponseStatus.ok
        if let fault = try? message.envelope.fault() {
            status = fault.code == .sender ? .badRequest : .internalServerError
        }
        let action = message.envelope.addressing?.action
        let mtom = !message.attachments.isEmpty || [XDSTransaction.provideAndRegister, .retrieveDocumentSet].contains { $0.responseAction == action }
        do {
            if mtom {
                let writer = MTOMWriter(action: action)
                let data = try await writer.data(message)
                return (status, writer.contentType.description, data)
            }
            let type = MIMEContentType("application/soap+xml", parameters: ["charset": "UTF-8"])
            return (status, type.description, try message.envelope.data())
        } catch {
            return (.internalServerError, "text/plain", Data("cannot write the response: \(error)".utf8))
        }
    }
}

/// Open connections and errors, shared by the connection tasks.
final class ServerState: @unchecked Sendable {
    private let lock = NSLock()
    private var channels: [ObjectIdentifier: Channel] = [:]
    private var stopped = false
    private var log: [String] = []

    func open(_ channel: Channel, limit: Int) -> Bool {
        lock.withLock {
            guard !stopped, channels.count < limit else { return false }
            channels[ObjectIdentifier(channel)] = channel
            return true
        }
    }

    func closed(_ channel: Channel) {
        lock.withLock { _ = channels.removeValue(forKey: ObjectIdentifier(channel)) }
    }

    /// Marks the server as stopping and returns the connections to close.
    func stopping() -> [Channel] {
        lock.withLock {
            stopped = true
            return Array(channels.values)
        }
    }

    var isStopping: Bool { lock.withLock { stopped } }

    func record(_ message: String) {
        lock.withLock { log.append(message) }
    }

    var errors: [String] { lock.withLock { log } }
}
