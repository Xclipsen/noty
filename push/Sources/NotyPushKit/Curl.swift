import Foundation

public struct HTTPRequest: Sendable, Equatable {
    public var url: String
    public var method = "POST"
    /// „name: value“ lines.
    public var headers: [String] = []
    public var body: Data?
    public var http2 = false
    public var maxTime = 30
    public var maxResponseBytes = 1_000_000

    public init(url: String, method: String = "POST", headers: [String] = [], body: Data? = nil, http2: Bool = false,
                maxTime: Int = 30, maxResponseBytes: Int = 1_000_000) {
        self.url = url; self.method = method; self.headers = headers; self.body = body; self.http2 = http2
        self.maxTime = maxTime; self.maxResponseBytes = maxResponseBytes
    }
}

public struct HTTPResponse: Sendable, Equatable {
    public var status: Int
    public var body: Data
    public init(status: Int, body: Data) { self.status = status; self.body = body }
}

public enum TransportError: Error, Equatable, CustomStringConvertible {
    case timeout
    case tooLarge
    case unreachable(Int32)
    case invalidRequest(String)

    public var description: String {
        switch self {
        case .timeout: "Zeitüberschreitung"
        case .tooLarge: "Antwort zu groß"
        case .unreachable(let code): "nicht erreichbar (curl \(code))"
        case .invalidRequest(let reason): "ungültige Anfrage (\(reason))"
        }
    }
}

public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

/// HTTPS via the system curl (HTTP/2 through nghttp2 for APNs). Everything,
/// including URL, headers and body, goes through curl's stdin as a config
/// file (`-K -`): no secret (JWT, device token, OTP) appears on a command
/// line or in a temporary file. `-q` ignores any ~/.curlrc. Only https, no
/// redirects followed, bounded time and size.
public struct CurlTransport: HTTPTransport {
    public let curlPath: String
    public init(curlPath: String) { self.curlPath = curlPath }

    /// Quoted value for curl's config syntax (backslash and quote escaped).
    static func quoted(_ text: String) throws -> String {
        guard !text.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
            throw TransportError.invalidRequest("Steuerzeichen")
        }
        return "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    public static func configText(_ request: HTTPRequest) throws -> String {
        guard request.url.hasPrefix("https://") else { throw TransportError.invalidRequest("nur https") }
        guard ["GET", "POST", "PUT", "DELETE"].contains(request.method) else { throw TransportError.invalidRequest("Methode") }
        var lines = [
            "url = " + (try quoted(request.url)),
            "request = " + (try quoted(request.method)),
            "proto = \"=https\"",
            "silent", "show-error",
            "connect-timeout = 10",
            "max-time = \(max(1, request.maxTime))",
            "max-filesize = \(max(1, request.maxResponseBytes))",
            "write-out = \"\\n%{http_code}\"",
            request.http2 ? "http2" : "http1.1",
        ]
        for header in request.headers {
            guard header.contains(":") else { throw TransportError.invalidRequest("Kopfzeile") }
            lines.append("header = " + (try quoted(header)))
        }
        if let body = request.body {
            guard let text = String(data: body, encoding: .utf8) else { throw TransportError.invalidRequest("Körper kein UTF-8") }
            // Never let curl read a file: a body starting with „@“ would be one.
            guard !text.hasPrefix("@") else { throw TransportError.invalidRequest("Körper") }
            lines.append("data-binary = " + (try quoted(text)))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Splits curl's output: body, then a newline and the HTTP status.
    static func parseOutput(_ output: Data) -> HTTPResponse? {
        guard let newline = output.lastIndex(of: 0x0A) else { return nil }
        let statusText = String(decoding: output[(newline + 1)...], as: UTF8.self)
        guard let status = Int(statusText.trimmingCharacters(in: .whitespaces)) else { return nil }
        return HTTPResponse(status: status, body: Data(output[..<newline]))
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let config = Data(try Self.configText(request).utf8)
        let path = curlPath
        let limit = request.maxResponseBytes + 64
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(with: Result { try Self.run(path: path, config: config, limit: limit) })
            }
        }
    }

    static func run(path: String, config: Data, limit: Int) throws -> HTTPResponse {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["-q", "-K", "-"]
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "C"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        // stderr is dropped: it can echo the URL (device token).
        process.standardError = FileHandle.nullDevice
        try process.run()
        let writer = DispatchQueue(label: "noty-push.curl.stdin")
        writer.async {
            input.fileHandleForWriting.write(config)
            try? input.fileHandleForWriting.close()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let code = process.terminationStatus
        switch code {
        case 0: break
        case 28: throw TransportError.timeout
        case 63: throw TransportError.tooLarge
        default: throw TransportError.unreachable(code)
        }
        guard data.count <= limit, let response = parseOutput(data) else { throw TransportError.tooLarge }
        return response
    }
}
