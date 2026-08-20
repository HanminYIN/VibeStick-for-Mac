import Foundation
import Testing

@Suite("Native Swift Bridge HTTP contract")
struct NativeBridgeCoreTests {
    @Test("health keeps the protocol and voice capability contract")
    func healthContract() throws {
        let store = MockNativeBridgeStore()
        let response = NativeBridgeRouter(store: store).response(
            to: NativeBridgeHTTPRequest(method: "GET", target: "/health")
        )
        let payload = response.jsonObject()

        #expect(response.status == 200)
        #expect(payload["ok"] as? Bool == true)
        #expect(payload["bridge_name"] as? String == "vibestick-bridge")
        #expect(payload["protocol_version"] as? Int == 2)
        #expect(payload["voice_interaction_version"] as? Int == 2)
        #expect(payload["bridge_id"] as? String == store.bridgeID)
    }

    @Test("health remains responsive while state observation is slow")
    func healthFastLane() {
        let stateStarted = DispatchSemaphore(value: 0)
        let releaseState = DispatchSemaphore(value: 0)
        let healthReturned = DispatchSemaphore(value: 0)
        let store = MockNativeBridgeStore()
        store.currentStateHandler = {
            stateStarted.signal()
            releaseState.wait()
            return ["active_provider": "codex"]
        }
        let coordinator = NativeBridgeRequestCoordinator(
            router: NativeBridgeRouter(store: store)
        )

        coordinator.respond(
            to: NativeBridgeHTTPRequest(method: "GET", target: "/state")
        ) { _ in }
        defer { releaseState.signal() }
        #expect(stateStarted.wait(timeout: .now() + 1) == .success)

        coordinator.respond(
            to: NativeBridgeHTTPRequest(method: "GET", target: "/health")
        ) { response in
            if response.status == 200 { healthReturned.signal() }
        }
        #expect(healthReturned.wait(timeout: .now() + 0.25) == .success)
    }

    @Test("state and device reads stay responsive while a mutation is slow")
    func readFastLane() {
        let mutationStarted = DispatchSemaphore(value: 0)
        let releaseMutation = DispatchSemaphore(value: 0)
        let stateReturned = DispatchSemaphore(value: 0)
        let devicesReturned = DispatchSemaphore(value: 0)
        let store = MockNativeBridgeStore()
        store.startRecordingHandler = { request in
            mutationStarted.signal()
            releaseMutation.wait()
            return store.recordingPayload(request: request)
        }
        let coordinator = NativeBridgeRequestCoordinator(
            router: NativeBridgeRouter(store: store)
        )

        coordinator.respond(
            to: NativeBridgeHTTPRequest(method: "POST", target: "/recording/start", body: Data("{}".utf8))
        ) { _ in }
        defer { releaseMutation.signal() }
        #expect(mutationStarted.wait(timeout: .now() + 1) == .success)

        coordinator.respond(
            to: NativeBridgeHTTPRequest(method: "GET", target: "/state")
        ) { response in
            if response.status == 200 { stateReturned.signal() }
        }
        coordinator.respond(
            to: NativeBridgeHTTPRequest(method: "GET", target: "/v1/devices")
        ) { response in
            if response.status == 200 { devicesReturned.signal() }
        }

        #expect(stateReturned.wait(timeout: .now() + 0.25) == .success)
        #expect(devicesReturned.wait(timeout: .now() + 0.25) == .success)
    }

    @Test("state is local by default and remote access needs an exact token")
    func stateAuthorization() throws {
        let store = MockNativeBridgeStore()
        store.bridgeToken = "fixed-fictional-token"
        let router = NativeBridgeRouter(store: store)

        let local = router.response(to: NativeBridgeHTTPRequest(method: "GET", target: "/state"))
        let remoteDenied = router.response(
            to: NativeBridgeHTTPRequest(
                method: "GET",
                target: "/state",
                headers: ["X-Vibe-Stick-Token": "wrong"],
                remoteAddress: "192.0.2.10"
            )
        )
        let remoteAllowed = router.response(
            to: NativeBridgeHTTPRequest(
                method: "GET",
                target: "/state",
                headers: ["X-Vibe-Stick-Token": "fixed-fictional-token"],
                remoteAddress: "192.0.2.10"
            )
        )

        #expect(local.status == 200)
        #expect(remoteDenied.status == 401)
        #expect(remoteAllowed.status == 200)
        #expect(remoteAllowed.jsonObject()["bridge_name"] as? String == "vibestick-bridge")
    }

    @Test("placeholder bridge tokens are missing credentials")
    func placeholderToken() {
        #expect(NativeBridgeSecurity.normalizedBridgeToken(" change-this-shared-token ").isEmpty)
        #expect(NativeBridgeSecurity.normalizedBridgeToken("fictional-secret") == "fictional-secret")
        #expect(NativeBridgeSecurity.hostRequiresCredential("0.0.0.0"))
        #expect(!NativeBridgeSecurity.hostRequiresCredential("127.0.0.1"))
        #expect(!NativeBridgeSecurity.hostRequiresCredential("::1"))
    }

    @Test("pairing hash matches the existing protocol vector")
    func pairingHash() {
        #expect(
            NativeBridgeSecurity.pairingTokenHash(
                saltHex: "0123456789abcdef0123456789abcdef",
                token: "device-token-abcdefghijklmnopqrstuvwxyz-123456"
            ) == "16a86745951317bdbae3d065086324ea6f3225ac8318d4fa68df176b3dfcae78"
        )
    }

    @Test("paired configuration and acknowledgements keep device scope")
    func deviceConfiguration() throws {
        let store = MockNativeBridgeStore()
        store.acceptedDeviceID = "vs-001122334455"
        store.acceptedDeviceToken = "device-token-abcdefghijklmnopqrstuvwxyz-123456"
        let router = NativeBridgeRouter(store: store)
        let headers = [
            "X-Vibe-Stick-Device-ID": store.acceptedDeviceID,
            "X-Vibe-Stick-Token": store.acceptedDeviceToken,
        ]

        let denied = router.response(
            to: NativeBridgeHTTPRequest(method: "GET", target: "/v1/device/config")
        )
        let allowed = router.response(
            to: NativeBridgeHTTPRequest(method: "GET", target: "/v1/device/config", headers: headers)
        )
        let acknowledgement = router.response(
            to: NativeBridgeHTTPRequest(
                method: "POST",
                target: "/v1/device/config/ack",
                headers: headers,
                body: try JSONSerialization.data(withJSONObject: ["revision": 3])
            )
        )

        #expect(denied.status == 401)
        #expect(allowed.status == 200)
        #expect(allowed.jsonObject()["revision"] as? Int == 3)
        #expect(acknowledgement.status == 200)
        #expect(acknowledgement.jsonObject()["accepted"] as? Bool == true)
        #expect(store.notedDeviceIDs == [store.acceptedDeviceID, store.acceptedDeviceID])
        #expect(store.acknowledgements == [3])
    }

    @Test("configuration acknowledgement rejects booleans and negative revisions")
    func invalidAcknowledgement() throws {
        let store = MockNativeBridgeStore()
        store.acceptedDeviceID = "vs-001122334455"
        store.acceptedDeviceToken = "device-token-abcdefghijklmnopqrstuvwxyz-123456"
        let headers = [
            "X-Vibe-Stick-Device-ID": store.acceptedDeviceID,
            "X-Vibe-Stick-Token": store.acceptedDeviceToken,
        ]
        let router = NativeBridgeRouter(store: store)

        for value: Any in [true, -1, 1.5, "3"] {
            let response = router.response(
                to: NativeBridgeHTTPRequest(
                    method: "POST",
                    target: "/v1/device/config/ack",
                    headers: headers,
                    body: try JSONSerialization.data(withJSONObject: ["revision": value])
                )
            )
            #expect(response.status == 400)
        }
        #expect(store.acknowledgements.isEmpty)
    }

    @Test("firmware recording responses omit transcript and private target detail")
    func compactFirmwareResponse() throws {
        let store = MockNativeBridgeStore()
        store.acceptedDeviceID = "vs-001122334455"
        store.acceptedDeviceToken = "device-token-abcdefghijklmnopqrstuvwxyz-123456"
        let sessionID = "0123456789abcdef0123456789abcdef"
        let response = NativeBridgeRouter(store: store).response(
            to: NativeBridgeHTTPRequest(
                method: "POST",
                target: "/recording/send/confirm",
                headers: [
                    "X-Vibe-Stick-Device-ID": store.acceptedDeviceID,
                    "X-Vibe-Stick-Token": store.acceptedDeviceToken,
                    "X-Vibe-Stick-Firmware-Name": "VibeStick",
                ],
                body: try JSONSerialization.data(withJSONObject: ["session_id": sessionID])
            )
        )
        let payload = response.jsonObject()
        let serialized = String(decoding: response.body, as: UTF8.self)

        #expect(response.status == 200)
        #expect(response.body.count < 2_048)
        #expect((payload["recording"] as? [String: Any])?["status"] as? String == "sent")
        #expect(!serialized.contains("fictional recognized text"))
        #expect(!serialized.contains("focus_fingerprint"))
    }

    @Test("recording audio is bounded before store delivery")
    func audioLimit() {
        let store = MockNativeBridgeStore()
        store.bridgeToken = "fixed-fictional-token"
        let response = NativeBridgeRouter(store: store, maxRecordingAudioBytes: 4).response(
            to: NativeBridgeHTTPRequest(
                method: "POST",
                target: "/recording/audio?session_id=fixed-session",
                headers: ["X-Vibe-Stick-Token": "fixed-fictional-token"],
                body: Data(repeating: 0x01, count: 5),
                remoteAddress: "192.0.2.10"
            )
        )

        #expect(response.status == 413)
        #expect(store.audioDeliveries == 0)
    }
}

private final class MockNativeBridgeStore: NativeBridgeRoutingStore {
    let bridgeID = "00000000-0000-4000-8000-000000000001"
    let bridgeVersion = "0.2.0-rc"
    var bridgeToken = ""
    var acceptedDeviceID = ""
    var acceptedDeviceToken = ""
    var notedDeviceIDs: [String] = []
    var acknowledgements: [Int] = []
    var audioDeliveries = 0
    var currentStateHandler: (() -> [String: Any])?
    var startRecordingHandler: (([String: Any]) -> [String: Any])?

    func authenticateDevice(id: String, token: String) -> Bool {
        id == acceptedDeviceID && token == acceptedDeviceToken && !id.isEmpty
    }

    func noteDeviceRequest(id: String, headers: [String: String]) {
        notedDeviceIDs.append(id)
    }

    func currentState() -> [String: Any] {
        if let currentStateHandler { return currentStateHandler() }
        return ["active_provider": "codex", "provider": ["status": "IDLE"]]
    }

    func devicesStatus() -> [String: Any] {
        ["bridge_id": bridgeID, "protocol_version": 2, "devices": []]
    }

    func currentDeviceConfiguration() -> [String: Any] {
        ["schema_version": 1, "revision": 3]
    }

    func acknowledgeConfiguration(deviceID: String, revision: Int) -> [String: Any] {
        acknowledgements.append(revision)
        return ["accepted": revision == 3, "current_revision": 3]
    }

    func update(event: [String: Any]) -> [String: Any] { currentState() }
    func refreshQuota() -> [String: Any] { currentState() }
    func startRecording(request: [String: Any]) -> [String: Any] {
        if let startRecordingHandler { return startRecordingHandler(request) }
        return recordingPayload(request: request)
    }

    func attachRecordingAudio(
        _ data: Data,
        sessionID: String,
        sampleRate: Int,
        channels: Int,
        bitsPerSample: Int
    ) -> [String: Any] {
        audioDeliveries += 1
        return recordingPayload(request: ["session_id": sessionID])
    }

    func stopRecording(request: [String: Any]) -> [String: Any] { recordingPayload(request: request) }
    func confirmRecordingSend(request: [String: Any]) -> [String: Any] { recordingPayload(request: request) }

    fileprivate func recordingPayload(request: [String: Any]) -> [String: Any] {
        let sessionID = request["session_id"] as? String ?? "0123456789abcdef0123456789abcdef"
        return [
            "voice_interaction_version": 2,
            "recording": [
                "session_id": sessionID,
                "status": "sent",
                "transcript": "fictional recognized text",
                "audio_file": "/private/fictional.wav",
            ],
            "send_session": [
                "session_id": sessionID,
                "phase": "sent",
                "target": ["focus_fingerprint": String(repeating: "a", count: 64)],
            ],
            "state": currentState(),
        ]
    }
}
