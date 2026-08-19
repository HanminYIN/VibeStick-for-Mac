import CryptoKit
import Darwin
import Foundation

struct NativeBridgeHTTPRequest {
    let method: String
    let target: String
    let headers: [String: String]
    let body: Data
    let remoteAddress: String

    init(
        method: String,
        target: String,
        headers: [String: String] = [:],
        body: Data = Data(),
        remoteAddress: String = "127.0.0.1"
    ) {
        self.method = method.uppercased()
        self.target = target
        self.headers = headers
        self.body = body
        self.remoteAddress = remoteAddress
    }

    func header(_ name: String) -> String {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value ?? ""
    }
}

struct NativeBridgeHTTPResponse {
    let status: Int
    let headers: [String: String]
    let body: Data

    func jsonObject() -> [String: Any] {
        guard let value = try? JSONSerialization.jsonObject(with: body),
              let object = value as? [String: Any] else {
            return [:]
        }
        return object
    }
}

protocol NativeBridgeRoutingStore: AnyObject {
    var bridgeID: String { get }
    var bridgeVersion: String { get }
    var bridgeToken: String { get }

    func authenticateDevice(id: String, token: String) -> Bool
    func noteDeviceRequest(id: String, headers: [String: String])
    func currentState() -> [String: Any]
    func devicesStatus() -> [String: Any]
    func currentDeviceConfiguration() -> [String: Any]
    func acknowledgeConfiguration(deviceID: String, revision: Int) -> [String: Any]
    func update(event: [String: Any]) -> [String: Any]
    func refreshQuota() -> [String: Any]
    func startRecording(request: [String: Any]) -> [String: Any]
    func attachRecordingAudio(
        _ data: Data,
        sessionID: String,
        sampleRate: Int,
        channels: Int,
        bitsPerSample: Int
    ) -> [String: Any]
    func stopRecording(request: [String: Any]) -> [String: Any]
    func confirmRecordingSend(request: [String: Any]) -> [String: Any]
}

enum NativeBridgeSecurity {
    static let placeholderTokens: Set<String> = [
        "change-this-shared-token",
        "paste-generated-token-here",
        "changeme",
        "change-me",
    ]

    static func normalizedBridgeToken(_ value: String) -> String {
        let token = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return placeholderTokens.contains(token.lowercased()) ? "" : token
    }

    static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices {
            difference |= left[index] ^ right[index]
        }
        return difference == 0
    }

    static func isLoopback(_ rawAddress: String) -> Bool {
        let address = rawAddress
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()
        if address == "localhost" || address == "::1" { return true }

        var ipv4 = in_addr()
        let parsed = address.withCString { pointer in
            inet_pton(AF_INET, pointer, &ipv4)
        }
        guard parsed == 1 else { return false }
        return UInt32(bigEndian: ipv4.s_addr) >> 24 == 127
    }

    static func hostRequiresCredential(_ rawHost: String) -> Bool {
        let host = rawHost
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard !host.isEmpty else { return true }
        return !isLoopback(host)
    }

    static func pairingTokenHash(saltHex: String, token: String) -> String {
        guard saltHex.count == 32,
              let salt = Data(hexadecimal: saltHex.lowercased()) else {
            return ""
        }
        var material = Data("vibestick-pairing-v1\0".utf8)
        material.append(salt)
        material.append(Data(token.utf8))
        return SHA256.hash(data: material).map { String(format: "%02x", $0) }.joined()
    }
}

final class NativeBridgeRouter {
    static let protectedPaths: Set<String> = [
        "/event",
        "/quota/refresh",
        "/recording/start",
        "/recording/audio",
        "/recording/stop",
        "/recording/send/confirm",
    ]

    private let store: NativeBridgeRoutingStore
    private let maxRecordingAudioBytes: Int

    init(store: NativeBridgeRoutingStore, maxRecordingAudioBytes: Int = 2_000_000) {
        self.store = store
        self.maxRecordingAudioBytes = max(1, maxRecordingAudioBytes)
    }

    func response(to request: NativeBridgeHTTPRequest) -> NativeBridgeHTTPResponse {
        let components = URLComponents(string: "http://vibestick.local\(request.target)")
        let path = components?.path.isEmpty == false ? components?.path ?? request.target : request.target
        let pairedDeviceID = authenticatedDeviceID(for: request)

        switch (request.method, path) {
        case ("GET", "/health"):
            return json([
                "ok": true,
                "bridge_name": "vibestick-bridge",
                "bridge_version": store.bridgeVersion,
                "protocol_version": 2,
                "voice_interaction_version": 2,
                "bridge_id": store.bridgeID,
            ])

        case ("GET", "/state"):
            guard NativeBridgeSecurity.isLoopback(request.remoteAddress)
                    || runtimeAuthorized(request, pairedDeviceID: pairedDeviceID) else {
                return error(401, "Unauthorized")
            }
            var state = store.currentState()
            state["bridge_name"] = "vibestick-bridge"
            state["bridge_version"] = store.bridgeVersion
            state["protocol_version"] = 2
            state["bridge_id"] = store.bridgeID
            return json(state)

        case ("GET", "/v1/devices"):
            guard NativeBridgeSecurity.isLoopback(request.remoteAddress) else {
                return error(403, "Local management endpoint")
            }
            return json(store.devicesStatus())

        case ("GET", "/v1/device/config"):
            guard let pairedDeviceID else {
                return error(401, "Paired device required")
            }
            store.noteDeviceRequest(id: pairedDeviceID, headers: request.headers)
            return json(store.currentDeviceConfiguration())

        case ("POST", "/v1/device/config/ack"):
            guard let pairedDeviceID else {
                return error(401, "Paired device required")
            }
            let body = jsonBody(request.body)
            guard let revision = integer(body["revision"]), revision >= 0 else {
                return error(400, "Invalid revision")
            }
            store.noteDeviceRequest(id: pairedDeviceID, headers: request.headers)
            return json(store.acknowledgeConfiguration(deviceID: pairedDeviceID, revision: revision))

        case ("POST", "/recording/send/confirm"):
            guard let pairedDeviceID else {
                return error(401, "Paired device required")
            }
            store.noteDeviceRequest(id: pairedDeviceID, headers: request.headers)
            return recordingJSON(store.confirmRecordingSend(request: jsonBody(request.body)), request: request)

        default:
            break
        }

        if request.method == "POST",
           Self.protectedPaths.contains(path),
           !runtimeAuthorized(request, pairedDeviceID: pairedDeviceID) {
            return error(401, "Unauthorized")
        }

        switch (request.method, path) {
        case ("POST", "/event"):
            return json(store.update(event: jsonBody(request.body)))

        case ("POST", "/quota/refresh"):
            return json(["refreshed": true, "state": store.refreshQuota()])

        case ("POST", "/recording/start"):
            return recordingJSON(store.startRecording(request: jsonBody(request.body)), request: request)

        case ("POST", "/recording/audio"):
            guard request.body.count <= maxRecordingAudioBytes else {
                return error(413, "Recording audio exceeds \(maxRecordingAudioBytes) bytes")
            }
            return recordingJSON(
                store.attachRecordingAudio(
                    request.body,
                    sessionID: queryValue("session_id", from: components),
                    sampleRate: positiveHeader("X-Vibe-Stick-Sample-Rate", request: request, fallback: 16_000),
                    channels: positiveHeader("X-Vibe-Stick-Channels", request: request, fallback: 1),
                    bitsPerSample: positiveHeader("X-Vibe-Stick-Bits-Per-Sample", request: request, fallback: 16)
                ),
                request: request
            )

        case ("POST", "/recording/stop"):
            return recordingJSON(store.stopRecording(request: jsonBody(request.body)), request: request)

        default:
            return error(404, "Unknown endpoint")
        }
    }

    private func authenticatedDeviceID(for request: NativeBridgeHTTPRequest) -> String? {
        let deviceID = request.header("X-Vibe-Stick-Device-ID")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !deviceID.isEmpty,
              store.authenticateDevice(id: deviceID, token: request.header("X-Vibe-Stick-Token")) else {
            return nil
        }
        return deviceID
    }

    private func runtimeAuthorized(
        _ request: NativeBridgeHTTPRequest,
        pairedDeviceID: String?
    ) -> Bool {
        if let pairedDeviceID {
            store.noteDeviceRequest(id: pairedDeviceID, headers: request.headers)
            return true
        }
        let expected = NativeBridgeSecurity.normalizedBridgeToken(store.bridgeToken)
        if expected.isEmpty {
            return NativeBridgeSecurity.isLoopback(request.remoteAddress)
        }
        return NativeBridgeSecurity.constantTimeEqual(request.header("X-Vibe-Stick-Token"), expected)
    }

    private func recordingJSON(
        _ payload: [String: Any],
        request: NativeBridgeHTTPRequest
    ) -> NativeBridgeHTTPResponse {
        guard !request.header("X-Vibe-Stick-Firmware-Name")
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return json(payload)
        }
        let recording = payload["recording"] as? [String: Any] ?? [:]
        let sendSession = payload["send_session"] as? [String: Any] ?? [:]
        return json([
            "voice_interaction_version": integer(payload["voice_interaction_version"]) ?? 2,
            "recording": [
                "session_id": recording["session_id"] as? String ?? "",
                "status": recording["status"] as? String ?? "",
            ],
            "send_session": [
                "session_id": sendSession["session_id"] as? String ?? "",
                "phase": sendSession["phase"] as? String ?? "",
            ],
        ])
    }

    private func json(_ object: [String: Any], status: Int = 200) -> NativeBridgeHTTPResponse {
        let body = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return NativeBridgeHTTPResponse(
            status: status,
            headers: [
                "Content-Type": "application/json; charset=utf-8",
                "Content-Length": String(body.count),
                "Access-Control-Allow-Origin": "http://127.0.0.1",
            ],
            body: body
        )
    }

    private func error(_ status: Int, _ message: String) -> NativeBridgeHTTPResponse {
        json(["error": message], status: status)
    }

    private func jsonBody(_ data: Data) -> [String: Any] {
        guard !data.isEmpty,
              let value = try? JSONSerialization.jsonObject(with: data),
              let object = value as? [String: Any] else {
            return [:]
        }
        return object
    }

    private func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.rounded() == number.doubleValue else {
            return nil
        }
        return number.intValue
    }

    private func queryValue(_ name: String, from components: URLComponents?) -> String {
        components?.queryItems?.first(where: { $0.name == name })?.value ?? ""
    }

    private func positiveHeader(
        _ name: String,
        request: NativeBridgeHTTPRequest,
        fallback: Int
    ) -> Int {
        guard let value = Int(request.header(name)), value > 0 else { return fallback }
        return value
    }
}

private extension Data {
    init?(hexadecimal: String) {
        guard hexadecimal.count.isMultiple(of: 2),
              hexadecimal.allSatisfy({ $0.isHexDigit }) else {
            return nil
        }
        var result = Data(capacity: hexadecimal.count / 2)
        var index = hexadecimal.startIndex
        while index < hexadecimal.endIndex {
            let next = hexadecimal.index(index, offsetBy: 2)
            guard let byte = UInt8(hexadecimal[index..<next], radix: 16) else { return nil }
            result.append(byte)
            index = next
        }
        self = result
    }
}
