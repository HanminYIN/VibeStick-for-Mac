import Foundation
import Testing

@Suite("Native Swift Bridge production state store")
struct NativeBridgeRuntimeStoreTests {
    @Test("provider observation becomes the compatible state document")
    func providerState() throws {
        try withStoreTemporaryDirectory { directory in
            let clock = FictionalStoreClock(epoch: 1_787_090_000)
            let store = try makeStore(directory: directory, clock: clock) {
                observationPair(
                    codexStatus: "RUNNING",
                    quota: NativeQuotaSnapshot(
                        quota5HRemaining: 81,
                        quota7DRemaining: 63,
                        quotaUpdatedAt: "18:00",
                        quotaSource: "codex-session-log",
                        quotaObservedAtEpoch: clock.epoch - 2
                    )
                )
            }
            let state = store.currentState()
            #expect(state["active_provider"] as? String == "codex")
            #expect((state["codex"] as? [String: Any])?["status"] as? String == "RUNNING")
            #expect((state["codex"] as? [String: Any])?["quota_7d_remaining"] as? Int == 63)

            let persisted = try JSONSerialization.jsonObject(
                with: Data(contentsOf: directory.appendingPathComponent("state.json"))
            ) as? [String: Any]
            #expect((persisted?["provider"] as? [String: Any])?["id"] as? String == "codex")
        }
    }

    @Test("explicit quota refresh prefers newer account-wide limits")
    func quotaRefresh() throws {
        try withStoreTemporaryDirectory { directory in
            let clock = FictionalStoreClock(epoch: 1_787_090_000)
            let account = NativeQuotaSnapshot(
                quota5HRemaining: 72,
                quota7DRemaining: 41,
                quotaUpdatedAt: "18:05",
                quotaSource: "codex-app-server",
                quotaObservedAtEpoch: clock.epoch
            )
            let store = try makeStore(
                directory: directory,
                clock: clock,
                observations: {
                    observationPair(
                        quota: NativeQuotaSnapshot(
                            quota5HRemaining: 90,
                            quota7DRemaining: 90,
                            quotaSource: "codex-session-log",
                            quotaObservedAtEpoch: clock.epoch - 10
                        )
                    )
                },
                fetchAccountQuota: { account }
            )
            let state = store.refreshQuota()
            #expect((state["codex"] as? [String: Any])?["quota_5h_remaining"] as? Int == 72)
            #expect(NativeQuotaStore(path: directory.appendingPathComponent("codex-quota.json")).load() == account)
        }
    }

    @Test("old quota remains visible but is marked stale")
    func staleQuota() throws {
        try withStoreTemporaryDirectory { directory in
            let clock = FictionalStoreClock(epoch: 1_787_090_000)
            try NativeQuotaStore(path: directory.appendingPathComponent("codex-quota.json")).save(
                NativeQuotaSnapshot(
                    quota5HRemaining: 50,
                    quota7DRemaining: 25,
                    quotaObservedAtEpoch: clock.epoch - 1_901
                )
            )
            let store = try makeStore(directory: directory, clock: clock) {
                observationPair(quota: NativeQuotaSnapshot())
            }
            let codex = store.currentState()["codex"] as? [String: Any]
            #expect(codex?["quota_7d_remaining"] as? Int == 25)
            #expect(codex?["quota_stale"] as? Bool == true)
        }
    }

    @Test("active Claude refresh is opt-in cached and failure-safe")
    func claudeQuotaRefresh() throws {
        try withStoreTemporaryDirectory { directory in
            let clock = FictionalStoreClock(epoch: 1_787_090_000)
            var response: NativeQuotaSnapshot? = NativeQuotaSnapshot(
                quota5HRemaining: 66,
                quota7DRemaining: 96,
                quotaUpdatedAt: "18:05",
                quotaSource: "claude-oauth-usage",
                quotaObservedAtEpoch: clock.epoch
            )
            var calls = 0
            let store = try makeStore(
                directory: directory,
                clock: clock,
                configuredProvider: "claude",
                observations: { observationPair(claudeOnline: true) },
                fetchClaudeQuota: {
                    calls += 1
                    return response
                },
                claudeUsageEnabled: true,
                claudeUsageInterval: 300
            )
            var provider = store.currentState()["provider"] as? [String: Any]
            #expect(provider?["id"] as? String == "claude")
            #expect(provider?["quota_5h_remaining"] as? Int == 66)
            #expect(calls == 1)

            _ = store.currentState()
            #expect(calls == 1)
            response = nil
            _ = store.refreshQuota()
            provider = store.currentState()["provider"] as? [String: Any]
            #expect(provider?["quota_7d_remaining"] as? Int == 96)
            #expect(provider?["quota_stale"] as? Bool == true)
            #expect(calls == 2)
            #expect(NativeQuotaStore(
                path: directory.appendingPathComponent("claude-quota.json")
            ).load().quotaStale)
        }
    }

    @Test("disabled Claude usage never resolves a credential or network response")
    func claudeDisabled() throws {
        try withStoreTemporaryDirectory { directory in
            let clock = FictionalStoreClock(epoch: 1_787_090_000)
            var calls = 0
            let store = try makeStore(
                directory: directory,
                clock: clock,
                configuredProvider: "claude",
                observations: { observationPair(claudeOnline: true) },
                fetchClaudeQuota: {
                    calls += 1
                    return NativeQuotaSnapshot(quota5HRemaining: 1)
                },
                claudeUsageEnabled: false
            )
            let provider = store.refreshQuota()["provider"] as? [String: Any]
            #expect(provider?["quota_5h_remaining"] is NSNull)
            #expect(calls == 0)
        }
    }

    @Test("manual status wins only inside its bounded compatibility window")
    func manualStatusWindow() throws {
        try withStoreTemporaryDirectory { directory in
            let clock = FictionalStoreClock(epoch: 1_787_090_000)
            let store = try makeStore(directory: directory, clock: clock) {
                observationPair(codexStatus: "IDLE")
            }
            let manual = store.update(event: ["status": "approval", "message": "Fictional approval"])
            #expect((manual["codex"] as? [String: Any])?["status"] as? String == "APPROVAL")
            #expect((manual["alert"] as? [String: Any])?["type"] as? String == "APPROVAL")

            clock.epoch += 61
            let refreshed = store.currentState()
            #expect((refreshed["codex"] as? [String: Any])?["status"] as? String == "IDLE")
            #expect((refreshed["alert"] as? [String: Any])?["type"] as? String == "NONE")
        }
    }

    @Test("paired device authentication status and configuration ack stay compatible")
    func pairedDeviceStatus() throws {
        try withStoreTemporaryDirectory { directory in
            let clock = FictionalStoreClock(epoch: 1_787_090_000)
            let token = "fictional-device-token-abcdefghijklmnopqrstuvwxyz"
            try writeStoreFixture([
                "schema_version": 1,
                "devices": [[
                    "device_id": "vs-001122334455",
                    "name": "Fictional Stick",
                    "token_salt": "0123456789abcdef0123456789abcdef",
                    "token_hash": NativeBridgeSecurity.pairingTokenHash(
                        saltHex: "0123456789abcdef0123456789abcdef",
                        token: token
                    ),
                    "paired_at": "2026-08-19T00:00:00Z",
                    "firmware_version": "0.1-test",
                    "revoked": false,
                ]],
            ], to: directory.appendingPathComponent("devices-v1.json"))
            try writeStoreFixture([
                "schema_version": 1,
                "revision": 7,
                "modules": ["codex", "connection"],
            ], to: directory.appendingPathComponent("device-config-v1.json"))
            let store = try makeStore(directory: directory, clock: clock) {
                observationPair()
            }

            #expect(store.authenticateDevice(id: "vs-001122334455", token: token))
            store.noteDeviceRequest(id: "vs-001122334455", headers: [
                "x-vibe-stick-firmware-version": "0.2-test",
            ])
            #expect(store.acknowledgeConfiguration(deviceID: "vs-001122334455", revision: 7)["accepted"] as? Bool == true)
            let device = ((store.devicesStatus()["devices"] as? [[String: Any]])?.first)
            #expect(device?["online"] as? Bool == true)
            #expect(device?["firmware_version"] as? String == "0.2-test")
            #expect(device?["last_config_revision"] as? Int == 7)
        }
    }

    @Test("voice response includes state without persisting transcript")
    func voiceResponsePrivacy() throws {
        try withStoreTemporaryDirectory { directory in
            let clock = FictionalStoreClock(epoch: 1_787_090_000)
            let store = try makeStore(directory: directory, clock: clock) {
                observationPair()
            }
            let response = store.startRecording(request: [
                "session_id": "fictional-session-01",
                "interaction_version": 2,
                "audio_source": "sticks3",
            ])
            #expect(response["state"] as? [String: Any] != nil)
            #expect((response["recording"] as? [String: Any])?["status"] as? String == "recording")
            let persisted = try String(
                contentsOf: directory.appendingPathComponent("recording.json"),
                encoding: .utf8
            )
            #expect(!persisted.contains("transcript\""))
            #expect(!persisted.contains("audio_file"))
        }
    }

    private func makeStore(
        directory: URL,
        clock: FictionalStoreClock,
        configuredProvider: String = "auto",
        observations: @escaping () -> NativeProviderObservationPair,
        fetchAccountQuota: @escaping () -> NativeQuotaSnapshot? = { nil },
        fetchClaudeQuota: @escaping () -> NativeQuotaSnapshot? = { nil },
        claudeUsageEnabled: Bool = false,
        claudeUsageInterval: TimeInterval = 300
    ) throws -> NativeBridgeRuntimeStore {
        let pending = NativePendingSendCoordinator(
            path: directory.appendingPathComponent("pending-send-v1.json"),
            clock: { clock.epoch }
        )
        let voice = NativeVoiceRecordingController(
            path: directory.appendingPathComponent("recording.json"),
            pendingSend: pending,
            recorder: FictionalStoreRecorder(),
            transcriber: FictionalStoreTranscriber(),
            pasteClient: FictionalStorePasteClient(),
            audioStore: FictionalStoreAudioStore(directory: directory),
            hud: FictionalStoreHUD(),
            now: { Date(timeIntervalSince1970: clock.epoch) },
            retryDelay: { _ in },
            managedSendMode: .confirm
        )
        return NativeBridgeRuntimeStore(
            bridgeID: "00112233-4455-6677-8899-aabbccddeeff",
            bridgeToken: "fictional-bridge-token",
            configuredProvider: configuredProvider,
            registry: NativePairedDeviceRegistry(path: directory.appendingPathComponent("devices-v1.json")),
            deviceConfiguration: NativeDeviceConfigurationStore(path: directory.appendingPathComponent("device-config-v1.json")),
            stateDocument: NativeBridgeStateDocument(path: directory.appendingPathComponent("state.json")),
            quotaStore: NativeQuotaStore(path: directory.appendingPathComponent("codex-quota.json")),
            claudeQuotaStore: NativeQuotaStore(path: directory.appendingPathComponent("claude-quota.json")),
            voice: voice,
            observeProviders: observations,
            fetchAccountQuota: fetchAccountQuota,
            fetchClaudeQuota: fetchClaudeQuota,
            claudeUsageEnabled: claudeUsageEnabled,
            claudeUsageInterval: claudeUsageInterval,
            now: { Date(timeIntervalSince1970: clock.epoch) }
        )
    }
}

private final class FictionalStoreClock {
    var epoch: TimeInterval
    init(epoch: TimeInterval) { self.epoch = epoch }
}

private func observationPair(
    codexStatus: String = "IDLE",
    quota: NativeQuotaSnapshot = NativeQuotaSnapshot(),
    claudeOnline: Bool = false
) -> NativeProviderObservationPair {
    NativeProviderObservationPair(
        codex: NativeProviderObservation(
            providerID: "codex",
            displayName: "Codex",
            online: true,
            status: codexStatus,
            project: "Fictional Project",
            quota: quota,
            alertType: "NONE",
            alertMessage: "",
            alertEventID: "",
            latestEventTimestamp: nil
        ),
        claude: NativeProviderObservation(
            providerID: "claude",
            displayName: "Claude",
            online: claudeOnline,
            status: claudeOnline ? "IDLE" : "OFFLINE",
            project: "Fictional Project",
            quota: NativeQuotaSnapshot(),
            alertType: "NONE",
            alertMessage: "",
            alertEventID: "",
            latestEventTimestamp: nil
        )
    )
}

private final class FictionalStoreRecorder: NativeVoiceRecorder {
    func start(sessionID: String) -> NativeVoiceRecorderResult? { nil }
    func stop() -> NativeVoiceRecorderResult? { nil }
}

private final class FictionalStoreTranscriber: NativeVoiceTranscriber {
    func transcribe(session: NativeVoiceRecordingSession, explicitText: String) -> NativeVoiceTranscriptionResult {
        NativeVoiceTranscriptionResult(text: explicitText, success: !explicitText.isEmpty, message: "fixture", source: "fixture")
    }
}

private final class FictionalStorePasteClient: NativeVoicePasteClient {
    func paste(text: String, pressEnter: Bool) -> NativeVoicePasteResult {
        NativeVoicePasteResult(success: true, message: "fixture", target: nil, delivery: "pasted")
    }
    func inspectTarget(expected: NativeSendTarget) -> NativeVoicePasteResult {
        NativeVoicePasteResult(success: true, message: "fixture", target: expected, delivery: "")
    }
    func confirmReturn(expected: NativeSendTarget) -> NativeVoicePasteResult {
        NativeVoicePasteResult(success: true, message: "fixture", target: expected, delivery: "")
    }
}

private final class FictionalStoreAudioStore: NativeVoiceAudioStore {
    let directory: URL
    init(directory: URL) { self.directory = directory }
    func writePCM(_ data: Data, sessionID: String, sampleRate: Int, channels: Int, bitsPerSample: Int) throws -> URL {
        directory.appendingPathComponent("fictional.wav")
    }
    func metrics(for url: URL) -> NativeVoiceAudioMetrics? { nil }
}

private final class FictionalStoreHUD: NativeVoiceHUDClient {
    func show(_ state: String, holdSeconds: TimeInterval?) {}
    func hide(delaySeconds: TimeInterval?) {}
}

private func withStoreTemporaryDirectory(_ operation: (URL) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("VibeStick-NativeStore-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    try operation(directory)
}

private func writeStoreFixture(_ object: [String: Any], to path: URL) throws {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: path)
}
