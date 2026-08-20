import Foundation
import Network

struct NativeBridgeHTTPParseError: Error, Equatable {
    let status: Int
    let message: String
}

enum NativeBridgeHTTPParseResult {
    case incomplete
    case request(NativeBridgeHTTPRequest)
    case failure(NativeBridgeHTTPParseError)
}

final class NativeBridgeHTTPParser: @unchecked Sendable {
    private var buffer = Data()
    private let maximumHeaderBytes: Int
    private let maximumBodyBytes: Int

    init(maximumHeaderBytes: Int = 65_536, maximumBodyBytes: Int = 2_000_000) {
        self.maximumHeaderBytes = max(1_024, maximumHeaderBytes)
        self.maximumBodyBytes = max(0, maximumBodyBytes)
    }

    func append(_ data: Data, remoteAddress: String) -> NativeBridgeHTTPParseResult {
        buffer.append(data)
        let separator = Data([13, 10, 13, 10])
        guard let headerRange = buffer.range(of: separator) else {
            if buffer.count > maximumHeaderBytes {
                return .failure(.init(status: 431, message: "Request headers are too large"))
            }
            return .incomplete
        }
        guard headerRange.lowerBound <= maximumHeaderBytes else {
            return .failure(.init(status: 431, message: "Request headers are too large"))
        }

        let rawHeader = buffer[..<headerRange.lowerBound]
        guard let headerText = String(data: rawHeader, encoding: .utf8) else {
            return .failure(.init(status: 400, message: "Invalid request headers"))
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            return .failure(.init(status: 400, message: "Invalid request line"))
        }
        let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard requestParts.count == 3,
              requestParts[2] == "HTTP/1.1" || requestParts[2] == "HTTP/1.0",
              !requestParts[0].isEmpty,
              requestParts[1].first == "/" else {
            return .failure(.init(status: 400, message: "Invalid request line"))
        }

        var headers: [String: String] = [:]
        var normalizedHeaders: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separatorIndex = line.firstIndex(of: ":") else {
                return .failure(.init(status: 400, message: "Invalid request header"))
            }
            let name = String(line[..<separatorIndex]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: separatorIndex)...])
                .trimmingCharacters(in: .whitespaces)
            guard Self.validHeaderName(name) else {
                return .failure(.init(status: 400, message: "Invalid request header"))
            }
            let normalized = name.lowercased()
            if let existing = normalizedHeaders[normalized], existing != value {
                return .failure(.init(status: 400, message: "Conflicting request header"))
            }
            normalizedHeaders[normalized] = value
            headers[name] = value
        }

        if let transferEncoding = normalizedHeaders["transfer-encoding"],
           !transferEncoding.isEmpty,
           transferEncoding.lowercased() != "identity" {
            return .failure(.init(status: 400, message: "Transfer-Encoding is unsupported"))
        }
        let contentLength: Int
        if let rawLength = normalizedHeaders["content-length"] {
            guard let parsed = Int(rawLength), parsed >= 0 else {
                return .failure(.init(status: 400, message: "Invalid Content-Length"))
            }
            contentLength = parsed
        } else {
            contentLength = 0
        }
        guard contentLength <= maximumBodyBytes else {
            return .failure(.init(status: 413, message: "Request body is too large"))
        }

        let bodyStart = headerRange.upperBound
        guard buffer.count >= bodyStart + contentLength else { return .incomplete }
        let body = buffer.subdata(in: bodyStart..<(bodyStart + contentLength))
        return .request(NativeBridgeHTTPRequest(
            method: String(requestParts[0]),
            target: String(requestParts[1]),
            headers: headers,
            body: body,
            remoteAddress: remoteAddress
        ))
    }

    private static func validHeaderName(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "!#$%&'*+-.^_`|~"))
        return name.unicodeScalars.allSatisfy { $0.isASCII && allowed.contains($0) }
    }
}

enum NativeBridgeBindPolicy {
    static func validate(host: String, bridgeToken: String, pairedDeviceCount: Int) throws {
        guard !NativeBridgeSecurity.hostRequiresCredential(host)
                || !NativeBridgeSecurity.normalizedBridgeToken(bridgeToken).isEmpty
                || pairedDeviceCount > 0 else {
            throw NativeBridgeHTTPParseError(
                status: 403,
                message: "Refusing non-loopback binding without a paired device or bridge token"
            )
        }
    }
}

enum NativeBridgeBonjour {
    static func textRecord(bridgeID: String) -> [String: Data] {
        [
            "bridge_id": Data(bridgeID.utf8),
            "protocol": Data("2".utf8),
            "auth": Data("paired".utf8),
        ]
    }

    static func encodedTextRecord(bridgeID: String) -> Data {
        NetService.data(fromTXTRecord: textRecord(bridgeID: bridgeID))
    }
}

final class NativeBridgeRequestCoordinator: @unchecked Sendable {
    private let router: NativeBridgeRouter
    private let readRouteQueue: DispatchQueue
    private let serializedRouteQueue: DispatchQueue

    init(
        router: NativeBridgeRouter,
        readRouteQueue: DispatchQueue = DispatchQueue(
            label: "com.vibestick.native-bridge.read-routes",
            attributes: .concurrent
        ),
        serializedRouteQueue: DispatchQueue = DispatchQueue(
            label: "com.vibestick.native-bridge.routes"
        )
    ) {
        self.router = router
        self.readRouteQueue = readRouteQueue
        self.serializedRouteQueue = serializedRouteQueue
    }

    func respond(
        to request: NativeBridgeHTTPRequest,
        completion: @escaping @Sendable (NativeBridgeHTTPResponse) -> Void
    ) {
        if Self.isHealthRequest(request) {
            completion(router.response(to: request))
            return
        }
        if Self.isFastReadRequest(request) {
            readRouteQueue.async { [self] in
                completion(router.response(to: request))
            }
            return
        }
        serializedRouteQueue.async { [self] in
            completion(router.response(to: request))
        }
    }

    private static func isHealthRequest(_ request: NativeBridgeHTTPRequest) -> Bool {
        request.method == "GET" && path(for: request) == "/health"
    }

    private static func isFastReadRequest(_ request: NativeBridgeHTTPRequest) -> Bool {
        guard request.method == "GET" else { return false }
        switch path(for: request) {
        case "/state", "/v1/devices":
            return true
        default:
            return false
        }
    }

    private static func path(for request: NativeBridgeHTTPRequest) -> String? {
        URLComponents(string: "http://vibestick.local\(request.target)")?.path
    }
}

final class NativeBridgeHTTPServer: @unchecked Sendable {
    private let requestCoordinator: NativeBridgeRequestCoordinator
    private let listener: NWListener
    private let queue: DispatchQueue
    private let maximumBodyBytes: Int
    private let stateLock = NSLock()
    private var started = false

    init(
        host: String,
        port: UInt16,
        bridgeID: String,
        bridgeToken: String,
        pairedDeviceCount: Int,
        router: NativeBridgeRouter,
        maximumBodyBytes: Int = 2_000_000,
        queue: DispatchQueue = DispatchQueue(label: "com.vibestick.native-bridge.http")
    ) throws {
        try NativeBridgeBindPolicy.validate(
            host: host,
            bridgeToken: bridgeToken,
            pairedDeviceCount: pairedDeviceCount
        )
        guard let networkPort = NWEndpoint.Port(rawValue: port) else {
            throw NativeBridgeHTTPParseError(status: 400, message: "Invalid bridge port")
        }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: networkPort)
        let listener = try NWListener(using: parameters)
        listener.service = NWListener.Service(
            name: "VibeStick Bridge",
            type: "_vibestick._tcp",
            domain: "local.",
            txtRecord: NativeBridgeBonjour.encodedTextRecord(bridgeID: bridgeID)
        )
        self.requestCoordinator = NativeBridgeRequestCoordinator(router: router)
        self.listener = listener
        self.maximumBodyBytes = max(0, maximumBodyBytes)
        self.queue = queue
    }

    func start() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !started else { return }
        started = true
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
    }

    func stop() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard started else { return }
        started = false
        listener.cancel()
    }

    private func accept(_ connection: NWConnection) {
        let parser = NativeBridgeHTTPParser(maximumBodyBytes: maximumBodyBytes)
        connection.stateUpdateHandler = { state in
            if case .failed = state { connection.cancel() }
        }
        connection.start(queue: queue)
        receive(connection, parser: parser, remoteAddress: Self.remoteAddress(connection.endpoint))
    }

    private func receive(
        _ connection: NWConnection,
        parser: NativeBridgeHTTPParser,
        remoteAddress: String
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            if let data, !data.isEmpty {
                switch parser.append(data, remoteAddress: remoteAddress) {
                case .incomplete:
                    break
                case let .request(request):
                    self.requestCoordinator.respond(to: request) { [weak self] response in
                        guard let self else {
                            connection.cancel()
                            return
                        }
                        self.send(response, on: connection)
                    }
                    return
                case let .failure(failure):
                    self.send(Self.errorResponse(failure), on: connection)
                    return
                }
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.receive(connection, parser: parser, remoteAddress: remoteAddress)
        }
    }

    private func send(_ response: NativeBridgeHTTPResponse, on connection: NWConnection) {
        connection.send(content: Self.wireResponse(response), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    static func wireResponse(_ response: NativeBridgeHTTPResponse) -> Data {
        var headers = response.headers
        headers["Connection"] = "close"
        headers["Content-Length"] = String(response.body.count)
        let phrase: String
        switch response.status {
        case 200: phrase = "OK"
        case 400: phrase = "Bad Request"
        case 401: phrase = "Unauthorized"
        case 403: phrase = "Forbidden"
        case 404: phrase = "Not Found"
        case 413: phrase = "Payload Too Large"
        case 431: phrase = "Request Header Fields Too Large"
        default: phrase = "Error"
        }
        var head = "HTTP/1.1 \(response.status) \(phrase)\r\n"
        for key in headers.keys.sorted() {
            head += "\(key): \(headers[key] ?? "")\r\n"
        }
        head += "\r\n"
        var result = Data(head.utf8)
        result.append(response.body)
        return result
    }

    private static func errorResponse(_ error: NativeBridgeHTTPParseError) -> NativeBridgeHTTPResponse {
        let body = (try? JSONSerialization.data(withJSONObject: ["error": error.message], options: [.sortedKeys]))
            ?? Data("{}".utf8)
        return NativeBridgeHTTPResponse(
            status: error.status,
            headers: [
                "Content-Type": "application/json; charset=utf-8",
                "Access-Control-Allow-Origin": "http://127.0.0.1",
            ],
            body: body
        )
    }

    private static func remoteAddress(_ endpoint: NWEndpoint) -> String {
        guard case let .hostPort(host, _) = endpoint else { return "" }
        switch host {
        case let .ipv4(address): return address.debugDescription
        case let .ipv6(address): return address.debugDescription
        case let .name(name, _): return name
        @unknown default: return ""
        }
    }
}
