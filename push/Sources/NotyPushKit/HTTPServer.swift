import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1

/// Plain HTTP/1.1 on the loopback interface only; TLS, the public path and
/// request filtering are nginx' job (push/deploy/nginx-noty-push.conf).
public final class HTTPServer {
    /// A connection that sends nothing for this long is closed (slow clients).
    public static let idleTimeout: TimeAmount = .seconds(30)
    /// How long one request may be processed: a registration fetches
    /// WebUntis twice with up to 40 s each (nginx waits 120 s). While a
    /// request is processed the idle timeout does not apply.
    public static let maximumProcessing: TimeAmount = .seconds(150)

    let router: APIRouter
    let host: String
    let port: Int
    let idleTimeout: TimeAmount
    let maximumProcessing: TimeAmount
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    private var channel: Channel?

    public init(router: APIRouter, host: String, port: Int, idleTimeout: TimeAmount = HTTPServer.idleTimeout,
                maximumProcessing: TimeAmount = HTTPServer.maximumProcessing) {
        self.router = router; self.host = host; self.port = port
        self.idleTimeout = idleTimeout; self.maximumProcessing = maximumProcessing
    }

    public func start() throws {
        guard ["127.0.0.1", "::1"].contains(host) else { throw PushError.configuration("nur Loopback") }
        let router = self.router
        let idleTimeout = self.idleTimeout, maximumProcessing = self.maximumProcessing
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 64)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let pipeline = channel.pipeline.syncOperations
                    try pipeline.addHandler(IdleStateHandler(readTimeout: idleTimeout))
                    try pipeline.configureHTTPServerPipeline(withErrorHandling: true)
                    try pipeline.addHandler(RequestHandler(router: router, maximumProcessing: maximumProcessing))
                }
            }
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 4)
        channel = try bootstrap.bind(host: host, port: port).wait()
        Log.info("lauscht auf \(host):\(port)")
    }

    public func stop() {
        try? channel?.close().wait()
        try? group.syncShutdownGracefully()
    }
}

final class RequestHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    let router: APIRouter
    let maximumProcessing: TimeAmount
    private var head: HTTPRequestHead?
    private var body = ByteBuffer()
    private var tooLarge = false
    /// A request is being processed since then (the client waits, sending nothing).
    private var processingSince: NIODeadline?

    init(router: APIRouter, maximumProcessing: TimeAmount) { self.router = router; self.maximumProcessing = maximumProcessing }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        guard event is IdleStateHandler.IdleStateEvent else { return context.fireUserInboundEventTriggered(event) }
        // Silence of a client that waits for its answer is no idleness; only
        // a request that takes longer than `maximumProcessing` is given up.
        if let since = processingSince, NIODeadline.now() - since < maximumProcessing { return }
        context.close(promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let value):
            head = value; body.clear(); tooLarge = false
            if let length = value.headers.first(name: "content-length").flatMap(Int.init), length > APIRouter.maximumBodyBytes { tooLarge = true }
        case .body(var chunk):
            if tooLarge { return }
            if body.readableBytes + chunk.readableBytes > APIRouter.maximumBodyBytes { tooLarge = true; body.clear(); return }
            body.writeBuffer(&chunk)
        case .end:
            guard let head else { return }
            self.head = nil
            if tooLarge {
                write(context: context, head: head, response: .error(413, "too_large", "Anfrage zu groß."), close: true)
                return
            }
            var headers: [String: String] = [:]
            for (name, value) in head.headers where headers[name.lowercased()] == nil { headers[name.lowercased()] = value }
            let parts = APIRequest.split(head.uri)
            // nginx sets X-Real-IP; the socket peer is always loopback here.
            let client = headers["x-real-ip"].flatMap { $0.count <= 64 ? $0 : nil } ?? context.remoteAddress?.ipAddress ?? "?"
            let request = APIRequest(method: head.method.rawValue, path: parts.path, query: parts.query, headers: headers,
                                     body: Data(body.readableBytesView), clientIP: client)
            let router = self.router
            let loop = context.eventLoop
            let bound = NIOLoopBound((self, context), eventLoop: loop)
            processingSince = .now()
            Task {
                let response = await router.handle(request)
                loop.execute {
                    let (handler, context) = bound.value
                    handler.processingSince = nil
                    guard context.channel.isActive else { return }
                    handler.write(context: context, head: head, response: response, close: !head.isKeepAlive)
                }
            }
        }
    }

    func write(context: ChannelHandlerContext, head: HTTPRequestHead, response: APIResponse, close: Bool) {
        var headers = HTTPHeaders()
        for (name, value) in response.headers { headers.add(name: name, value: value) }
        headers.add(name: "Content-Length", value: String(response.body.count))
        if close { headers.add(name: "Connection", value: "close") }
        let status = HTTPResponseStatus(statusCode: response.status)
        context.write(wrapOutboundOut(.head(HTTPResponseHead(version: head.version, status: status, headers: headers))), promise: nil)
        if !response.body.isEmpty {
            var buffer = context.channel.allocator.buffer(capacity: response.body.count)
            buffer.writeBytes(response.body)
            context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        }
        let done = context.writeAndFlush(wrapOutboundOut(.end(nil)))
        if close { done.whenComplete { _ in context.close(promise: nil) } }
    }
}
