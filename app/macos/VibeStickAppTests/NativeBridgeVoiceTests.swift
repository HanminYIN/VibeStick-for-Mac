import Foundation
import Testing

@Suite("Native Swift Bridge voice and send safety")
struct NativeBridgeVoiceTests {
    @Test("send target validation limits compatibility fallback to ChatGPT")
    func targetValidation() {
        let fingerprint = String(repeating: "a", count: 64)
        #expect(NativeSendTarget.normalized(
            bundleID: "com.example.Editor",
            processID: 42,
            focusFingerprint: fingerprint
        ) != nil)
        #expect(NativeSendTarget.normalized(
            bundleID: "com.example.Editor",
            processID: 42,
            focusFingerprint: fingerprint,
            verificationScope: NativeSendTarget.chatGPTWindowScope
        ) == nil)
        #expect(NativeSendTarget.normalized(
            bundleID: "com.openai.codex",
            processID: 42,
            focusFingerprint: fingerprint,
            verificationScope: NativeSendTarget.chatGPTWindowScope
        ) != nil)
        #expect(NativeSendTarget.normalized(
            bundleID: "../../bad",
            processID: 42,
            focusFingerprint: fingerprint
        ) == nil)
    }

    @Test("pending send persists before granting one confirmation")
    func pendingSendAtMostOnce() throws {
        try withVoiceTemporaryDirectory { directory in
            var now = 100.0
            let coordinator = NativePendingSendCoordinator(
                path: directory.appendingPathComponent("pending.json"),
                clock: { now }
            )
            let target = voiceTarget()
            let armed = coordinator.arm(sessionID: voiceSessionID, target: target)
            #expect(armed.accepted)
            #expect(coordinator.arm(sessionID: voiceSessionID, target: target).reason == "pending_send_already_armed")

            now = 101
            let first = coordinator.beginConfirmation(
                sessionID: voiceSessionID,
                currentTarget: target
            )
            #expect(first.shouldPressEnter)
            #expect(!coordinator.beginConfirmation(
                sessionID: voiceSessionID,
                currentTarget: target
            ).shouldPressEnter)
            #expect(coordinator.finishConfirmation(sessionID: voiceSessionID, success: true).snapshot.phase == .sent)
            #expect(coordinator.finishConfirmation(sessionID: voiceSessionID, success: true).reason == "confirmation_already_sent")

            let persisted = try voiceJSON(directory.appendingPathComponent("pending.json"))
            #expect(persisted["phase"] as? String == "sent")
        }
    }

    @Test("compatibility target expires sooner and new recording invalidates pending send")
    func pendingSendExpiryAndInvalidation() throws {
        try withVoiceTemporaryDirectory { directory in
            var now = 200.0
            let coordinator = NativePendingSendCoordinator(
                path: directory.appendingPathComponent("pending.json"),
                clock: { now },
                ttl: 30
            )
            let target = NativeSendTarget.normalized(
                bundleID: "com.openai.codex",
                processID: 88,
                focusFingerprint: String(repeating: "b", count: 64),
                verificationScope: NativeSendTarget.chatGPTWindowScope
            )!
            let armed = coordinator.arm(sessionID: voiceSessionID, target: target)
            #expect(armed.snapshot.expiresAtEpoch == 215)
            now = 210
            #expect(coordinator.beginRecording(sessionID: "new-session-1234").reason == "previous_pending_send_invalidated")
            #expect(coordinator.snapshot().phase == .invalidated)

            let secondPath = directory.appendingPathComponent("pending-2.json")
            let second = NativePendingSendCoordinator(path: secondPath, clock: { now })
            #expect(second.arm(sessionID: voiceSessionID, target: voiceTarget()).accepted)
            now = 241
            #expect(second.snapshot().phase == .expired)
        }
    }

    @Test("restart invalidates a half-consumed confirmation")
    func confirmationRestartRecovery() throws {
        try withVoiceTemporaryDirectory { directory in
            let path = directory.appendingPathComponent("pending.json")
            let first = NativePendingSendCoordinator(path: path, clock: { 300 })
            #expect(first.arm(sessionID: voiceSessionID, target: voiceTarget()).accepted)
            #expect(first.beginConfirmation(
                sessionID: voiceSessionID,
                currentTarget: voiceTarget()
            ).shouldPressEnter)

            let recovered = NativePendingSendCoordinator(path: path, clock: { 301 })
            #expect(recovered.snapshot().phase == .invalidated)
            #expect(recovered.snapshot().reason == "bridge_restarted_during_confirmation")
        }
    }

    @Test("StickS3 start waits for upload without touching the microphone")
    func stickStartAvoidsMicrophone() throws {
        try withVoiceFixture { fixture in
            let result = fixture.controller.start(request: [
                "session_id": voiceSessionID,
                "audio_source": "StickS3 PCM",
                "interaction_version": 2,
                "send_mode": "confirm",
            ])
            let recording = result["recording"] as? [String: Any]
            #expect(recording?["status"] as? String == "recording")
            #expect(recording?["audio_source"] as? String == "sticks3_pcm")
            #expect(fixture.recorder.startCalls == 0)
            #expect(fixture.hud.shown.last?.0 == "listening")
        }
    }

    @Test("PCM upload fails closed on empty, mismatched, and non-16-bit input")
    func invalidPCMUpload() throws {
        try withVoiceFixture { fixture in
            _ = fixture.controller.start(request: [
                "session_id": voiceSessionID,
                "audio_source": "sticks3",
                "interaction_version": 2,
            ])
            var result = fixture.controller.attachPCM(
                Data(),
                sessionID: voiceSessionID,
                sampleRate: 16_000,
                channels: 1,
                bitsPerSample: 16
            )
            #expect(voiceStatus(result) == "audio_failed")

            result = fixture.controller.attachPCM(
                Data([0, 1]),
                sessionID: "different-session",
                sampleRate: 16_000,
                channels: 1,
                bitsPerSample: 16
            )
            #expect(voiceStatus(result) == "audio_failed")

            result = fixture.controller.attachPCM(
                Data([0, 1]),
                sessionID: voiceSessionID,
                sampleRate: 16_000,
                channels: 1,
                bitsPerSample: 24
            )
            #expect(voiceStatus(result) == "audio_failed")
            #expect(fixture.audioStore.writeCalls == 0)
        }
    }

    @Test("M3-B stop rejects a mismatched session before transcription or paste")
    func mismatchedStop() throws {
        try withVoiceFixture { fixture in
            _ = fixture.controller.start(request: [
                "session_id": voiceSessionID,
                "audio_source": "sticks3",
                "interaction_version": 2,
            ])
            let result = fixture.controller.stop(request: [
                "session_id": "different-session",
                "text": "must not escape",
            ])
            #expect(voiceStatus(result) == "stop_failed")
            #expect(fixture.transcriber.calls == 0)
            #expect(fixture.paste.pasteCalls == 0)
        }
    }

    @Test("audio quality gates run before cloud transcription")
    func audioQualityGate() throws {
        try withVoiceFixture { fixture in
            fixture.audioStore.metricsResult = NativeVoiceAudioMetrics(
                durationSeconds: 2,
                audioBytes: 64_000,
                rms: 1_000,
                acRMS: 950,
                speechSeconds: 0.2,
                speechWindows: 2
            )
            _ = fixture.controller.start(request: [
                "session_id": voiceSessionID,
                "audio_source": "sticks3",
                "interaction_version": 2,
            ])
            _ = fixture.controller.attachPCM(
                Data([0, 0, 1, 0]),
                sessionID: voiceSessionID,
                sampleRate: 16_000,
                channels: 1,
                bitsPerSample: 16
            )
            let result = fixture.controller.stop(request: ["session_id": voiceSessionID])
            #expect(voiceStatus(result) == "audio_skipped")
            #expect(fixture.transcriber.calls == 0)
        }
    }

    @Test("known hallucinations never reach the clipboard")
    func hallucinationRejection() throws {
        try withVoiceFixture { fixture in
            fixture.transcriber.result = NativeVoiceTranscriptionResult(
                text: "请使用简体中文输出。",
                success: true,
                message: "ASR complete",
                source: "fictional"
            )
            _ = fixture.controller.start(request: [
                "session_id": voiceSessionID,
                "audio_source": "sticks3",
                "interaction_version": 2,
            ])
            let result = fixture.controller.stop(request: ["session_id": voiceSessionID])
            #expect(voiceStatus(result) == "transcript_rejected")
            #expect(fixture.paste.pasteCalls == 0)
        }
    }

    @Test("confirmation rechecks focus twice and presses Return once")
    func confirmedSend() throws {
        try withVoiceFixture { fixture in
            fixture.paste.pasteResult = NativeVoicePasteResult(
                success: true,
                message: "Pasted",
                target: voiceTarget(),
                delivery: "pasted"
            )
            fixture.paste.inspectionResults = [
                NativeVoicePasteResult(success: false, message: "Transient", target: nil, delivery: ""),
                NativeVoicePasteResult(success: true, message: "Verified", target: voiceTarget(), delivery: ""),
            ]
            _ = fixture.controller.start(request: [
                "session_id": voiceSessionID,
                "audio_source": "sticks3",
                "interaction_version": 2,
                "send_mode": "confirm",
            ])
            let stopped = fixture.controller.stop(request: [
                "session_id": voiceSessionID,
                "text": "hello from fixture",
            ])
            #expect(voiceStatus(stopped) == "pending_send")
            let confirmed = fixture.controller.confirmSend(request: ["session_id": voiceSessionID])
            #expect(voiceStatus(confirmed) == "sent")
            #expect(fixture.paste.inspectCalls == 2)
            #expect(fixture.paste.confirmCalls == 1)
            #expect(fixture.delays == [0.12])

            _ = fixture.controller.confirmSend(request: ["session_id": voiceSessionID])
            #expect(fixture.paste.confirmCalls == 1)
        }
    }

    @Test("changed focus invalidates confirmation without Return")
    func changedFocus() throws {
        try withVoiceFixture { fixture in
            fixture.paste.pasteResult = NativeVoicePasteResult(
                success: true,
                message: "Pasted",
                target: voiceTarget(),
                delivery: "pasted"
            )
            let changed = NativeSendTarget.normalized(
                bundleID: "com.example.Other",
                processID: 99,
                focusFingerprint: String(repeating: "c", count: 64)
            )!
            fixture.paste.inspectionResults = [
                NativeVoicePasteResult(success: true, message: "Changed", target: changed, delivery: ""),
            ]
            _ = fixture.controller.start(request: [
                "session_id": voiceSessionID,
                "audio_source": "sticks3",
                "interaction_version": 2,
                "send_mode": "confirm",
            ])
            _ = fixture.controller.stop(request: [
                "session_id": voiceSessionID,
                "text": "hello",
            ])
            let result = fixture.controller.confirmSend(request: ["session_id": voiceSessionID])
            let send = result["send_session"] as? [String: Any]
            #expect(send?["phase"] as? String == "invalidated")
            #expect(fixture.paste.confirmCalls == 0)
        }
    }

    @Test("persisted recording state omits transcript, message, and audio path")
    func recordingPrivacy() throws {
        try withVoiceFixture { fixture in
            fixture.paste.pasteResult = NativeVoicePasteResult(
                success: true,
                message: "Clipboard only",
                target: nil,
                delivery: "clipboard"
            )
            _ = fixture.controller.start(request: [
                "session_id": voiceSessionID,
                "audio_source": "sticks3",
                "interaction_version": 2,
            ])
            let result = fixture.controller.stop(request: [
                "session_id": voiceSessionID,
                "text": "private transcript fixture",
            ])
            #expect(voiceStatus(result) == "copied")
            let persisted = try voiceJSON(fixture.statePath)
            #expect(persisted["schema_version"] as? Int == 2)
            #expect(persisted["status"] as? String == "copied")
            #expect(persisted["transcript"] == nil)
            #expect(persisted["message"] == nil)
            #expect(persisted["audio_file"] == nil)
            let raw = try String(contentsOf: fixture.statePath, encoding: .utf8)
            #expect(!raw.contains("private transcript fixture"))
            let attributes = try FileManager.default.attributesOfItem(atPath: fixture.statePath.path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        }
    }
}

private let voiceSessionID = "0123456789abcdef0123456789abcdef"

private func voiceTarget() -> NativeSendTarget {
    NativeSendTarget.normalized(
        bundleID: "com.openai.codex",
        processID: 42,
        focusFingerprint: String(repeating: "a", count: 64)
    )!
}

private func voiceStatus(_ response: [String: Any]) -> String {
    (response["recording"] as? [String: Any])?["status"] as? String ?? ""
}

private func withVoiceTemporaryDirectory(_ operation: (URL) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("VibeStick-NativeVoice-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    try operation(directory)
}

private func voiceJSON(_ url: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: url)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private final class VoiceRecorderFixture: NativeVoiceRecorder {
    var startCalls = 0
    var stopCalls = 0
    var startResult: NativeVoiceRecorderResult?
    var stopResult: NativeVoiceRecorderResult?

    func start(sessionID: String) -> NativeVoiceRecorderResult? {
        startCalls += 1
        return startResult
    }

    func stop() -> NativeVoiceRecorderResult? {
        stopCalls += 1
        return stopResult
    }
}

private final class VoiceTranscriberFixture: NativeVoiceTranscriber {
    var calls = 0
    var result = NativeVoiceTranscriptionResult(
        text: "hello from fixture",
        success: true,
        message: "Fixture transcript",
        source: "fixture"
    )

    func transcribe(
        session: NativeVoiceRecordingSession,
        explicitText: String
    ) -> NativeVoiceTranscriptionResult {
        calls += 1
        if !explicitText.isEmpty {
            return NativeVoiceTranscriptionResult(
                text: explicitText,
                success: true,
                message: "Transcript supplied by request",
                source: "request"
            )
        }
        return result
    }
}

private final class VoicePasteFixture: NativeVoicePasteClient {
    var pasteCalls = 0
    var inspectCalls = 0
    var confirmCalls = 0
    var pasteResult = NativeVoicePasteResult(
        success: true,
        message: "Pasted",
        target: voiceTarget(),
        delivery: "pasted"
    )
    var inspectionResults: [NativeVoicePasteResult] = []
    var confirmResult = NativeVoicePasteResult(
        success: true,
        message: "Sent",
        target: voiceTarget(),
        delivery: "pasted"
    )

    func paste(text: String, pressEnter: Bool) -> NativeVoicePasteResult {
        pasteCalls += 1
        return pasteResult
    }

    func inspectTarget(expected: NativeSendTarget) -> NativeVoicePasteResult {
        inspectCalls += 1
        if inspectionResults.isEmpty {
            return NativeVoicePasteResult(success: true, message: "Verified", target: expected, delivery: "")
        }
        return inspectionResults.removeFirst()
    }

    func confirmReturn(expected: NativeSendTarget) -> NativeVoicePasteResult {
        confirmCalls += 1
        return confirmResult
    }
}

private final class VoiceAudioStoreFixture: NativeVoiceAudioStore {
    let directory: URL
    var writeCalls = 0
    var metricsResult: NativeVoiceAudioMetrics?

    init(directory: URL) {
        self.directory = directory
    }

    func writePCM(
        _ data: Data,
        sessionID: String,
        sampleRate: Int,
        channels: Int,
        bitsPerSample: Int
    ) throws -> URL {
        writeCalls += 1
        let url = directory.appendingPathComponent("\(sessionID).wav")
        try data.write(to: url)
        return url
    }

    func metrics(for url: URL) -> NativeVoiceAudioMetrics? {
        metricsResult
    }
}

private final class VoiceHUDClientFixture: NativeVoiceHUDClient {
    var shown: [(String, TimeInterval?)] = []
    var hidden: [TimeInterval?] = []

    func show(_ state: String, holdSeconds: TimeInterval?) {
        shown.append((state, holdSeconds))
    }

    func hide(delaySeconds: TimeInterval?) {
        hidden.append(delaySeconds)
    }
}

private final class VoiceFixture {
    let statePath: URL
    let recorder: VoiceRecorderFixture
    let transcriber: VoiceTranscriberFixture
    let paste: VoicePasteFixture
    let audioStore: VoiceAudioStoreFixture
    let hud: VoiceHUDClientFixture
    let delayBox: VoiceDelayBox
    var delays: [TimeInterval] { delayBox.values }
    let controller: NativeVoiceRecordingController

    init(directory: URL) {
        statePath = directory.appendingPathComponent("recording.json")
        recorder = VoiceRecorderFixture()
        transcriber = VoiceTranscriberFixture()
        paste = VoicePasteFixture()
        audioStore = VoiceAudioStoreFixture(directory: directory)
        hud = VoiceHUDClientFixture()
        delayBox = VoiceDelayBox()
        let pending = NativePendingSendCoordinator(
            path: directory.appendingPathComponent("pending.json"),
            clock: { 1_000 }
        )
        let capturedDelays = delayBox
        controller = NativeVoiceRecordingController(
            path: statePath,
            pendingSend: pending,
            recorder: recorder,
            transcriber: transcriber,
            pasteClient: paste,
            audioStore: audioStore,
            hud: hud,
            now: { Date(timeIntervalSince1970: 1_000) },
            retryDelay: { capturedDelays.values.append($0) }
        )
    }
}

private final class VoiceDelayBox {
    var values: [TimeInterval] = []
}

private func withVoiceFixture(_ operation: (VoiceFixture) throws -> Void) throws {
    try withVoiceTemporaryDirectory { directory in
        let fixture = VoiceFixture(directory: directory)
        try operation(fixture)
    }
}
