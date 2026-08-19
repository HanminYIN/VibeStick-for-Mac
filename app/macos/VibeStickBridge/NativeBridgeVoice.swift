import Foundation

enum NativeVoiceSendMode: String, CaseIterable {
    case pasteOnly = "paste_only"
    case confirm
    case autoSend = "auto_send"

    static func normalized(_ raw: Any?, interactionVersion: Int) -> NativeVoiceSendMode {
        let value = String(describing: raw ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
        switch value {
        case "paste", "paste_only": return .pasteOnly
        case "confirm", "blue_button": return .confirm
        case "auto", "auto_send": return .autoSend
        default: return .pasteOnly
        }
    }
}

enum NativeSendSessionPhase: String, CaseIterable {
    case idle
    case pending
    case confirming
    case sent
    case failed
    case invalidated
    case expired
}

struct NativeSendTarget: Equatable {
    static let focusedInputScope = "focused_input"
    static let chatGPTWindowScope = "chatgpt_window"
    static let chatGPTCompatibilityBundleIDs: Set<String> = ["com.openai.codex"]

    let bundleID: String
    let processID: Int
    let focusFingerprint: String
    let verificationScope: String

    static func normalized(
        bundleID: String,
        processID: Int,
        focusFingerprint: String,
        verificationScope: String = focusedInputScope
    ) -> NativeSendTarget? {
        let bundle = String(bundleID.trimmingCharacters(in: .whitespacesAndNewlines).prefix(255))
        let fingerprint = focusFingerprint
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let scope = verificationScope
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let allowedBundleCharacters = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "-_."))
        guard !bundle.isEmpty,
              bundle.unicodeScalars.allSatisfy({ $0.isASCII && allowedBundleCharacters.contains($0) }),
              processID > 0,
              fingerprint.count == 64,
              fingerprint.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              [focusedInputScope, chatGPTWindowScope].contains(scope),
              scope != chatGPTWindowScope || chatGPTCompatibilityBundleIDs.contains(bundle) else {
            return nil
        }
        return NativeSendTarget(
            bundleID: bundle,
            processID: processID,
            focusFingerprint: fingerprint,
            verificationScope: scope
        )
    }

    static func fromJSON(_ raw: Any?) -> NativeSendTarget? {
        guard let object = raw as? [String: Any],
              let processID = nativeVoiceInteger(object["process_id"]) else { return nil }
        return normalized(
            bundleID: object["bundle_id"] as? String ?? "",
            processID: processID,
            focusFingerprint: object["focus_fingerprint"] as? String ?? "",
            verificationScope: object["verification_scope"] as? String ?? focusedInputScope
        )
    }

    func jsonObject() -> [String: Any] {
        [
            "bundle_id": bundleID,
            "process_id": processID,
            "focus_fingerprint": focusFingerprint,
            "verification_scope": verificationScope,
        ]
    }
}

struct NativeSendSessionSnapshot: Equatable {
    let sessionID: String
    let phase: NativeSendSessionPhase
    let target: NativeSendTarget?
    let createdAtEpoch: TimeInterval
    let expiresAtEpoch: TimeInterval
    let updatedAtEpoch: TimeInterval
    let reason: String

    static let idle = NativeSendSessionSnapshot(
        sessionID: "",
        phase: .idle,
        target: nil,
        createdAtEpoch: 0,
        expiresAtEpoch: 0,
        updatedAtEpoch: 0,
        reason: ""
    )

    func jsonObject() -> [String: Any] {
        [
            "schema_version": 1,
            "session_id": sessionID,
            "phase": phase.rawValue,
            "target": target?.jsonObject() ?? NSNull(),
            "created_at_epoch": createdAtEpoch,
            "expires_at_epoch": expiresAtEpoch,
            "updated_at_epoch": updatedAtEpoch,
            "reason": reason,
        ]
    }
}

struct NativeSendSessionTransition {
    let accepted: Bool
    let shouldPressEnter: Bool
    let reason: String
    let snapshot: NativeSendSessionSnapshot

    func jsonObject() -> [String: Any] {
        [
            "accepted": accepted,
            "should_press_enter": shouldPressEnter,
            "reason": reason,
            "send_session": snapshot.jsonObject(),
        ]
    }
}

final class NativePendingSendCoordinator {
    static let defaultTTL: TimeInterval = 30
    static let compatibilityTTL: TimeInterval = 15
    static let minimumTTL: TimeInterval = 5
    static let maximumTTL: TimeInterval = 300

    private let path: URL
    private let clock: () -> TimeInterval
    private let ttl: TimeInterval
    private let lock = NSLock()
    private var storedSnapshot: NativeSendSessionSnapshot

    init(
        path: URL,
        clock: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 },
        ttl: TimeInterval = defaultTTL
    ) {
        precondition(ttl.isFinite && (Self.minimumTTL...Self.maximumTTL).contains(ttl))
        self.path = path
        self.clock = clock
        self.ttl = ttl
        self.storedSnapshot = Self.load(path: path)
        if storedSnapshot.phase == .confirming {
            let now = normalizedNow()
            let recovered = replacing(
                storedSnapshot,
                phase: .invalidated,
                updatedAt: now,
                reason: "bridge_restarted_during_confirmation"
            )
            if persist(recovered) { storedSnapshot = recovered }
        } else {
            expireIfNeeded()
        }
    }

    func snapshot() -> NativeSendSessionSnapshot {
        withLock {
            expireIfNeeded()
            return storedSnapshot
        }
    }

    func arm(sessionID rawSessionID: String, target: NativeSendTarget) -> NativeSendSessionTransition {
        let sessionID = nativeVoiceCleanSessionID(rawSessionID)
        return withLock {
            expireIfNeeded()
            guard !sessionID.isEmpty else { return transition(false, false, "invalid_pending_send_context") }
            if storedSnapshot.sessionID == sessionID {
                if storedSnapshot.phase == .pending, storedSnapshot.target == target {
                    return transition(true, false, "pending_send_already_armed")
                }
                if storedSnapshot.phase != .idle {
                    return transition(false, false, "pending_send_session_already_consumed")
                }
            }
            if [.pending, .confirming].contains(storedSnapshot.phase) {
                return transition(false, false, "another_pending_send_exists")
            }
            let now = normalizedNow()
            let effectiveTTL = target.verificationScope == NativeSendTarget.chatGPTWindowScope
                ? min(ttl, Self.compatibilityTTL) : ttl
            let candidate = NativeSendSessionSnapshot(
                sessionID: sessionID,
                phase: .pending,
                target: target,
                createdAtEpoch: now,
                expiresAtEpoch: now + effectiveTTL,
                updatedAtEpoch: now,
                reason: "awaiting_blue_button_confirmation"
            )
            guard persist(candidate) else {
                return transition(false, false, "pending_send_persistence_failed")
            }
            storedSnapshot = candidate
            return transition(true, false, "pending_send_armed")
        }
    }

    func beginRecording(sessionID rawSessionID: String) -> NativeSendSessionTransition {
        let sessionID = nativeVoiceCleanSessionID(rawSessionID)
        return withLock {
            expireIfNeeded()
            guard !sessionID.isEmpty else { return transition(false, false, "invalid_recording_session") }
            if storedSnapshot.phase == .confirming {
                return transition(false, false, "confirmation_in_progress")
            }
            if storedSnapshot.phase == .pending {
                let candidate = replacing(
                    storedSnapshot,
                    phase: .invalidated,
                    updatedAt: normalizedNow(),
                    reason: "invalidated_by_new_recording"
                )
                guard persist(candidate) else {
                    return transition(false, false, "pending_send_persistence_failed")
                }
                storedSnapshot = candidate
                return transition(true, false, "previous_pending_send_invalidated")
            }
            return transition(true, false, "recording_may_start")
        }
    }

    func beginConfirmation(
        sessionID rawSessionID: String,
        currentTarget: NativeSendTarget
    ) -> NativeSendSessionTransition {
        let sessionID = nativeVoiceCleanSessionID(rawSessionID)
        return withLock {
            expireIfNeeded()
            guard !sessionID.isEmpty else { return transition(false, false, "invalid_confirmation_session") }
            guard storedSnapshot.sessionID == sessionID else {
                return transition(false, false, "pending_send_session_mismatch")
            }
            if [.confirming, .sent].contains(storedSnapshot.phase) {
                return transition(false, false, "confirmation_already_consumed")
            }
            guard storedSnapshot.phase == .pending else {
                return transition(false, false, "pending_send_\(storedSnapshot.phase.rawValue)")
            }
            guard currentTarget == storedSnapshot.target else {
                let candidate = replacing(
                    storedSnapshot,
                    phase: .invalidated,
                    updatedAt: normalizedNow(),
                    reason: "focused_target_changed"
                )
                if persist(candidate) { storedSnapshot = candidate }
                return transition(false, false, "focused_target_changed")
            }
            let candidate = replacing(
                storedSnapshot,
                phase: .confirming,
                updatedAt: normalizedNow(),
                reason: "confirmation_consumed"
            )
            guard persist(candidate) else {
                return transition(false, false, "pending_send_persistence_failed")
            }
            storedSnapshot = candidate
            return transition(true, true, "press_enter_once")
        }
    }

    func invalidate(sessionID rawSessionID: String, reason rawReason: String) -> NativeSendSessionTransition {
        let sessionID = nativeVoiceCleanSessionID(rawSessionID)
        let reason = nativeVoiceCleanReason(rawReason)
        return withLock {
            guard !sessionID.isEmpty, storedSnapshot.sessionID == sessionID else {
                return transition(false, false, "pending_send_session_mismatch")
            }
            guard storedSnapshot.phase == .pending else {
                return transition(false, false, "pending_send_not_pending")
            }
            let candidate = replacing(
                storedSnapshot,
                phase: .invalidated,
                updatedAt: normalizedNow(),
                reason: reason
            )
            guard persist(candidate) else {
                return transition(false, false, "pending_send_persistence_failed")
            }
            storedSnapshot = candidate
            return transition(true, false, reason)
        }
    }

    func finishConfirmation(sessionID rawSessionID: String, success: Bool) -> NativeSendSessionTransition {
        let sessionID = nativeVoiceCleanSessionID(rawSessionID)
        return withLock {
            guard !sessionID.isEmpty, storedSnapshot.sessionID == sessionID else {
                return transition(false, false, "confirmation_session_mismatch")
            }
            if storedSnapshot.phase == .sent {
                return transition(false, false, "confirmation_already_sent")
            }
            guard storedSnapshot.phase == .confirming else {
                return transition(false, false, "confirmation_not_in_progress")
            }
            let reason = success ? "sent" : "return_key_failed"
            let candidate = replacing(
                storedSnapshot,
                phase: success ? .sent : .failed,
                updatedAt: normalizedNow(),
                reason: reason
            )
            guard persist(candidate) else {
                return transition(false, false, "pending_send_persistence_failed")
            }
            storedSnapshot = candidate
            return transition(true, false, reason)
        }
    }

    private static func load(path: URL) -> NativeSendSessionSnapshot {
        guard let data = try? NativeBridgeSecureFile.readData(at: path, maximumBytes: 32_768),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              nativeVoiceInteger(object["schema_version"]) == 1,
              let phase = NativeSendSessionPhase(rawValue: object["phase"] as? String ?? "idle") else {
            return .idle
        }
        if phase == .idle { return .idle }
        let sessionID = nativeVoiceCleanSessionID(object["session_id"] as? String ?? "")
        guard !sessionID.isEmpty, let target = NativeSendTarget.fromJSON(object["target"]) else {
            return .idle
        }
        return NativeSendSessionSnapshot(
            sessionID: sessionID,
            phase: phase,
            target: target,
            createdAtEpoch: nativeVoiceFiniteEpoch(object["created_at_epoch"]),
            expiresAtEpoch: nativeVoiceFiniteEpoch(object["expires_at_epoch"]),
            updatedAtEpoch: nativeVoiceFiniteEpoch(object["updated_at_epoch"]),
            reason: String((object["reason"] as? String ?? "").prefix(96))
        )
    }

    private func expireIfNeeded() {
        guard storedSnapshot.phase == .pending,
              storedSnapshot.expiresAtEpoch <= normalizedNow() else { return }
        let candidate = replacing(
            storedSnapshot,
            phase: .expired,
            updatedAt: normalizedNow(),
            reason: "pending_send_expired"
        )
        if persist(candidate) { storedSnapshot = candidate }
    }

    private func persist(_ snapshot: NativeSendSessionSnapshot) -> Bool {
        do {
            try NativeBridgeSecureFile.writeJSONAtomically(snapshot.jsonObject(), to: path)
            return true
        } catch {
            return false
        }
    }

    private func transition(
        _ accepted: Bool,
        _ shouldPressEnter: Bool,
        _ reason: String
    ) -> NativeSendSessionTransition {
        NativeSendSessionTransition(
            accepted: accepted,
            shouldPressEnter: shouldPressEnter,
            reason: reason,
            snapshot: storedSnapshot
        )
    }

    private func normalizedNow() -> TimeInterval {
        let value = clock()
        return value.isFinite && value >= 0 ? value : 0
    }

    private func withLock<T>(_ operation: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}

struct NativeVoiceRecordingSession {
    var sessionID = ""
    var active = false
    var startedAt = ""
    var stoppedAt = ""
    var status = "idle"
    var message = ""
    var transcript = ""
    var transcriptSource = "none"
    var pasted = false
    var audioFile = ""
    var audioSource = "none"
    var interactionVersion = 1
    var sendMode: NativeVoiceSendMode = .pasteOnly

    func jsonObject() -> [String: Any] {
        [
            "session_id": sessionID,
            "active": active,
            "started_at": startedAt,
            "stopped_at": stoppedAt,
            "status": status,
            "message": message,
            "transcript": transcript,
            "transcript_source": transcriptSource,
            "pasted": pasted,
            "audio_file": audioFile,
            "audio_source": audioSource,
            "interaction_version": interactionVersion,
            "send_mode": sendMode.rawValue,
        ]
    }

    func persistedJSONObject() -> [String: Any] {
        [
            "schema_version": 2,
            "session_id": sessionID,
            "active": active,
            "started_at": startedAt,
            "stopped_at": stoppedAt,
            "status": status,
            "transcript_source": transcriptSource,
            "pasted": pasted,
            "audio_source": audioSource,
            "interaction_version": interactionVersion,
            "send_mode": sendMode.rawValue,
        ]
    }
}

struct NativeVoiceRecorderResult {
    let success: Bool
    let audioFile: URL?
    let message: String
}

struct NativeVoiceTranscriptionResult {
    let text: String
    let success: Bool
    let message: String
    let source: String
}

struct NativeVoicePasteResult {
    let success: Bool
    let message: String
    let target: NativeSendTarget?
    let delivery: String
}

struct NativeVoiceAudioMetrics {
    let durationSeconds: Double
    let audioBytes: Int
    let rms: Double
    let acRMS: Double
    let speechSeconds: Double
    let speechWindows: Int
}

protocol NativeVoiceRecorder: AnyObject {
    func start(sessionID: String) -> NativeVoiceRecorderResult?
    func stop() -> NativeVoiceRecorderResult?
}

protocol NativeVoiceTranscriber: AnyObject {
    func transcribe(
        session: NativeVoiceRecordingSession,
        explicitText: String
    ) -> NativeVoiceTranscriptionResult
}

protocol NativeVoicePasteClient: AnyObject {
    func paste(text: String, pressEnter: Bool) -> NativeVoicePasteResult
    func inspectTarget(expected: NativeSendTarget) -> NativeVoicePasteResult
    func confirmReturn(expected: NativeSendTarget) -> NativeVoicePasteResult
}

protocol NativeVoiceAudioStore: AnyObject {
    func writePCM(
        _ data: Data,
        sessionID: String,
        sampleRate: Int,
        channels: Int,
        bitsPerSample: Int
    ) throws -> URL
    func metrics(for url: URL) -> NativeVoiceAudioMetrics?
}

protocol NativeVoiceHUDClient: AnyObject {
    func show(_ state: String, holdSeconds: TimeInterval?)
    func hide(delaySeconds: TimeInterval?)
}

final class NativeVoiceRecordingController {
    static let supportedInteractionVersion = 2
    static let minimumAudioDuration: TimeInterval = 0.7
    static let minimumAudioRMS = 120.0
    static let minimumSpeechSeconds: TimeInterval = 0.28
    static let minimumSpeechWindows = 3
    static let knownASRHallucinations = [
        "请不吝点赞订阅转发打赏支持明镜与点点栏目",
        "请使用简体中文输出。",
    ]

    private let path: URL
    private let pendingSend: NativePendingSendCoordinator
    private let recorder: NativeVoiceRecorder
    private let transcriber: NativeVoiceTranscriber
    private let pasteClient: NativeVoicePasteClient
    private let audioStore: NativeVoiceAudioStore
    private let hud: NativeVoiceHUDClient
    private let now: () -> Date
    private let retryDelay: (TimeInterval) -> Void
    private let managedSendMode: NativeVoiceSendMode?
    private(set) var session: NativeVoiceRecordingSession

    init(
        path: URL,
        pendingSend: NativePendingSendCoordinator,
        recorder: NativeVoiceRecorder,
        transcriber: NativeVoiceTranscriber,
        pasteClient: NativeVoicePasteClient,
        audioStore: NativeVoiceAudioStore,
        hud: NativeVoiceHUDClient,
        now: @escaping () -> Date = Date.init,
        retryDelay: @escaping (TimeInterval) -> Void = Thread.sleep,
        managedSendMode: NativeVoiceSendMode? = nil
    ) {
        self.path = path
        self.pendingSend = pendingSend
        self.recorder = recorder
        self.transcriber = transcriber
        self.pasteClient = pasteClient
        self.audioStore = audioStore
        self.hud = hud
        self.now = now
        self.retryDelay = retryDelay
        self.managedSendMode = managedSendMode
        self.session = Self.load(path: path)
    }

    func start(request: [String: Any]) -> [String: Any] {
        let requestedSource = String(describing: request["audio_source"] ?? request["source"] ?? "")
        let requestedID = nativeVoiceCleanSessionID(request["session_id"] as? String ?? "")
        let sessionID = requestedID.isEmpty
            ? UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            : requestedID
        let interactionVersion = nativeVoiceInteractionVersion(request["interaction_version"])
        let sendMode = managedSendMode
            ?? NativeVoiceSendMode.normalized(request["send_mode"], interactionVersion: interactionVersion)
        let transition = pendingSend.beginRecording(sessionID: sessionID)
        session = NativeVoiceRecordingSession(
            sessionID: sessionID,
            active: true,
            startedAt: timestamp(),
            status: "recording",
            message: "Recording session started",
            interactionVersion: interactionVersion,
            sendMode: sendMode
        )
        guard transition.accepted else {
            session.active = false
            session.stoppedAt = timestamp()
            session.status = "start_failed"
            session.message = "A send confirmation is already in progress"
            save()
            return response()
        }

        let usesMacMicrophone = !requestedSource.lowercased().contains("sticks3")
        if !usesMacMicrophone {
            session.audioSource = "sticks3_pcm"
            session.message = "Waiting for StickS3 audio upload"
            hud.show("listening", holdSeconds: nil)
        } else if let result = recorder.start(sessionID: sessionID) {
            session.audioFile = result.audioFile?.path ?? ""
            session.audioSource = "mac_mic"
            session.message = result.message
            if !result.success {
                session.active = false
                session.stoppedAt = timestamp()
                session.status = "start_failed"
                hud.show("failed", holdSeconds: 1.8)
                save()
                return response()
            }
            hud.show("listening", holdSeconds: nil)
        }
        save()
        return response()
    }

    func attachPCM(
        _ data: Data,
        sessionID rawSessionID: String,
        sampleRate: Int,
        channels: Int,
        bitsPerSample: Int
    ) -> [String: Any] {
        guard !data.isEmpty else {
            return audioFailure("Uploaded audio was empty")
        }
        let requestedID = nativeVoiceCleanSessionID(rawSessionID)
        if !requestedID.isEmpty,
           !session.sessionID.isEmpty,
           requestedID != session.sessionID,
           session.active {
            return audioFailure("Uploaded audio session did not match active recording")
        }
        if !requestedID.isEmpty, session.sessionID != requestedID {
            session = NativeVoiceRecordingSession(
                sessionID: requestedID,
                active: true,
                startedAt: timestamp(),
                status: "recording",
                message: "Recovered recording session from StickS3 audio upload",
                audioSource: "sticks3_pcm"
            )
        }
        guard bitsPerSample == 16 else {
            return audioFailure("Only 16-bit PCM audio is supported")
        }
        let sessionID = session.sessionID.isEmpty
            ? UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            : session.sessionID
        do {
            let url = try audioStore.writePCM(
                data,
                sessionID: sessionID,
                sampleRate: max(1, sampleRate),
                channels: max(1, channels),
                bitsPerSample: bitsPerSample
            )
            session.sessionID = sessionID
            session.audioFile = url.path
            session.audioSource = "sticks3_pcm"
            session.message = "StickS3 audio uploaded"
            hud.show("sending", holdSeconds: nil)
            save()
            return response()
        } catch {
            return audioFailure("Could not store uploaded audio")
        }
    }

    func stop(request: [String: Any]) -> [String: Any] {
        session.active = false
        session.stoppedAt = timestamp()
        var explicitText = String(describing: request["text"] ?? request["transcript"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let result = recorder.stop() {
            if let url = result.audioFile { session.audioFile = url.path }
            session.audioSource = "mac_mic"
            if !result.success {
                session.status = "stop_failed"
                session.message = result.message
                hud.show("failed", holdSeconds: 1.8)
                save()
                return response()
            }
        }
        let requestedID = nativeVoiceCleanSessionID(request["session_id"] as? String ?? "")
        if session.interactionVersion >= Self.supportedInteractionVersion,
           requestedID != session.sessionID {
            session.pasted = false
            session.status = "stop_failed"
            session.message = "Recording stop session did not match the active M3-B session"
            hud.show("failed", holdSeconds: 1.8)
            save()
            return response()
        }

        let shouldPaste = nativeVoiceBool(request["paste"], defaultValue: true)
        hud.show("transcribing", holdSeconds: nil)
        if explicitText.isEmpty, !session.audioFile.isEmpty,
           let metrics = audioStore.metrics(for: URL(fileURLWithPath: session.audioFile)) {
            if metrics.durationSeconds < Self.minimumAudioDuration {
                return skipAudio(String(format: "Audio too short for transcription: %.2fs", metrics.durationSeconds))
            }
            if metrics.rms < Self.minimumAudioRMS {
                return skipAudio(String(format: "Audio appears silent: rms=%.1f", metrics.rms))
            }
            if metrics.speechSeconds < Self.minimumSpeechSeconds
                || metrics.speechWindows < Self.minimumSpeechWindows {
                return skipAudio(String(
                    format: "No clear speech detected before transcription: speech_seconds=%.2f",
                    metrics.speechSeconds
                ))
            }
        }

        let result = transcriber.transcribe(session: session, explicitText: explicitText)
        session.transcriptSource = result.source
        guard result.success, !result.text.isEmpty else {
            session.pasted = false
            session.status = "transcription_failed"
            session.message = result.message
            hud.show("failed", holdSeconds: 1.8)
            save()
            return response()
        }
        explicitText = result.text
        session.transcript = result.text
        if Self.transcriptRejectionReason(result.text) != nil {
            session.pasted = false
            session.status = "transcript_rejected"
            session.message = "Rejected known ASR hallucination transcript"
            hud.show("unclear", holdSeconds: 1.8)
            save()
            return response()
        }

        guard shouldPaste else {
            session.pasted = false
            session.status = "transcribed"
            session.message = result.message
            hud.hide(delaySeconds: 0.5)
            save()
            return response()
        }

        let paste = pasteClient.paste(text: explicitText, pressEnter: session.sendMode == .autoSend)
        let clipboardOnly = paste.success && paste.delivery == "clipboard"
        session.pasted = paste.success && !clipboardOnly
        if clipboardOnly, session.interactionVersion >= Self.supportedInteractionVersion {
            session.status = "copied"
            session.message = paste.message
        } else if paste.success,
                  session.interactionVersion >= Self.supportedInteractionVersion,
                  session.sendMode == .confirm {
            if let target = paste.target {
                let armed = pendingSend.arm(sessionID: session.sessionID, target: target)
                session.status = armed.accepted ? "pending_send" : "confirmation_unavailable"
                session.message = armed.accepted
                    ? "Text pasted; waiting for blue-button confirmation"
                    : "Text was pasted, but confirmation could not be armed"
            } else {
                session.status = "confirmation_unavailable"
                session.message = "Text was pasted, but the focused input could not be identified"
            }
        } else if paste.success,
                  session.interactionVersion >= Self.supportedInteractionVersion,
                  session.sendMode == .autoSend {
            session.status = "sent"
            session.message = paste.message
        } else {
            session.status = paste.success ? "pasted" : "paste_failed"
            session.message = paste.success ? paste.message : "\(result.message); \(paste.message)"
        }
        if paste.success { hud.hide(delaySeconds: 0.5) }
        else { hud.show("failed", holdSeconds: 1.8) }
        save()
        return response()
    }

    func confirmSend(request: [String: Any]) -> [String: Any] {
        let sessionID = request["session_id"] as? String ?? ""
        let snapshot = pendingSend.snapshot()
        guard snapshot.phase == .pending, let target = snapshot.target else {
            let transition: NativeSendSessionTransition
            if let target = snapshot.target {
                transition = pendingSend.beginConfirmation(sessionID: sessionID, currentTarget: target)
            } else {
                transition = NativeSendSessionTransition(
                    accepted: false,
                    shouldPressEnter: false,
                    reason: "pending_send_\(snapshot.phase.rawValue)",
                    snapshot: snapshot
                )
            }
            return confirmationResponse(transition)
        }

        var inspection = pasteClient.inspectTarget(expected: target)
        if !inspection.success || inspection.target == nil {
            retryDelay(0.12)
            inspection = pasteClient.inspectTarget(expected: target)
        }
        guard inspection.success, let currentTarget = inspection.target else {
            let transition = pendingSend.invalidate(
                sessionID: sessionID,
                reason: "target_inspection_failed"
            )
            recordConfirmation(transition, message: "Focused input could not be verified")
            return confirmationResponse(transition)
        }
        let transition = pendingSend.beginConfirmation(
            sessionID: sessionID,
            currentTarget: currentTarget
        )
        guard transition.shouldPressEnter, let expectedTarget = transition.snapshot.target else {
            recordConfirmation(transition, message: "Focused input changed; Return was not sent")
            return confirmationResponse(transition)
        }
        let action = pasteClient.confirmReturn(expected: expectedTarget)
        let finished = pendingSend.finishConfirmation(sessionID: sessionID, success: action.success)
        recordConfirmation(finished, message: action.message)
        return confirmationResponse(finished)
    }

    private func response() -> [String: Any] {
        [
            "voice_interaction_version": Self.supportedInteractionVersion,
            "recording": session.jsonObject(),
            "send_session": pendingSend.snapshot().jsonObject(),
        ]
    }

    private func confirmationResponse(_ transition: NativeSendSessionTransition) -> [String: Any] {
        var value = response()
        value["confirmation"] = transition.jsonObject()
        return value
    }

    private func recordConfirmation(_ transition: NativeSendSessionTransition, message: String) {
        guard transition.snapshot.sessionID == session.sessionID else { return }
        switch transition.snapshot.phase {
        case .sent:
            session.status = "sent"
            session.message = message
            hud.hide(delaySeconds: nil)
        case .failed, .invalidated, .expired:
            session.status = "send_failed"
            session.message = message
            hud.show("send_failed", holdSeconds: 1.8)
        default:
            break
        }
        save()
    }

    private func audioFailure(_ message: String) -> [String: Any] {
        session.status = "audio_failed"
        session.message = message
        hud.show("failed", holdSeconds: 1.8)
        save()
        return response()
    }

    private func skipAudio(_ message: String) -> [String: Any] {
        session.pasted = false
        session.status = "audio_skipped"
        session.message = message
        hud.show("unclear", holdSeconds: 1.8)
        save()
        return response()
    }

    private func save() {
        try? NativeBridgeSecureFile.writeJSONAtomically(session.persistedJSONObject(), to: path)
    }

    private func timestamp() -> String {
        ISO8601DateFormatter().string(from: now())
    }

    private static func load(path: URL) -> NativeVoiceRecordingSession {
        guard let data = try? NativeBridgeSecureFile.readData(at: path, maximumBytes: 32_768),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              nativeVoiceInteger(object["schema_version"]) == 2 else {
            return NativeVoiceRecordingSession()
        }
        let interactionVersion = nativeVoiceInteractionVersion(object["interaction_version"])
        return NativeVoiceRecordingSession(
            sessionID: nativeVoiceCleanSessionID(object["session_id"] as? String ?? ""),
            active: nativeVoiceBool(object["active"], defaultValue: false),
            startedAt: object["started_at"] as? String ?? "",
            stoppedAt: object["stopped_at"] as? String ?? "",
            status: object["status"] as? String ?? "idle",
            transcriptSource: object["transcript_source"] as? String ?? "none",
            pasted: nativeVoiceBool(object["pasted"], defaultValue: false),
            audioSource: object["audio_source"] as? String ?? "none",
            interactionVersion: interactionVersion,
            sendMode: NativeVoiceSendMode.normalized(
                object["send_mode"],
                interactionVersion: interactionVersion
            )
        )
    }

    static func transcriptRejectionReason(_ text: String) -> String? {
        let normalized = text.components(separatedBy: .whitespacesAndNewlines)
            .joined()
            .lowercased()
        return knownASRHallucinations.contains(where: { normalized.contains($0.lowercased()) })
            ? "Rejected known ASR hallucination transcript" : nil
    }
}

private func nativeVoiceInteractionVersion(_ raw: Any?) -> Int {
    guard let value = nativeVoiceInteger(raw) else { return 1 }
    return max(1, min(NativeVoiceRecordingController.supportedInteractionVersion, value))
}

private func nativeVoiceInteger(_ raw: Any?) -> Int? {
    guard let number = raw as? NSNumber,
          CFGetTypeID(number) != CFBooleanGetTypeID(),
          number.doubleValue.isFinite,
          number.doubleValue.rounded() == number.doubleValue else { return nil }
    return number.intValue
}

private func nativeVoiceBool(_ raw: Any?, defaultValue: Bool) -> Bool {
    guard let number = raw as? NSNumber,
          CFGetTypeID(number) == CFBooleanGetTypeID() else { return defaultValue }
    return number.boolValue
}

private func nativeVoiceCleanSessionID(_ raw: String) -> String {
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard (8...64).contains(value.count),
          value.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else {
        return ""
    }
    return value
}

private func nativeVoiceCleanReason(_ raw: String) -> String {
    let value = String(raw
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
        .replacingOccurrences(of: "-", with: "_")
        .prefix(64))
    guard !value.isEmpty,
          value.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else {
        return "pending_send_invalidated"
    }
    return value
}

private func nativeVoiceFiniteEpoch(_ raw: Any?) -> TimeInterval {
    guard let number = raw as? NSNumber,
          CFGetTypeID(number) != CFBooleanGetTypeID(),
          number.doubleValue.isFinite,
          number.doubleValue >= 0 else { return 0 }
    return number.doubleValue
}

private func replacing(
    _ snapshot: NativeSendSessionSnapshot,
    phase: NativeSendSessionPhase,
    updatedAt: TimeInterval,
    reason: String
) -> NativeSendSessionSnapshot {
    NativeSendSessionSnapshot(
        sessionID: snapshot.sessionID,
        phase: phase,
        target: snapshot.target,
        createdAtEpoch: snapshot.createdAtEpoch,
        expiresAtEpoch: snapshot.expiresAtEpoch,
        updatedAtEpoch: updatedAt,
        reason: reason
    )
}
