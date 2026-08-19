import Foundation

struct NativeProviderObservationPair {
    var codex: NativeProviderObservation
    var claude: NativeProviderObservation
}

final class NativeProviderRuntimeObserver {
    private let homeDirectory: URL
    private let fallbackProject: String
    private let fileSource: NativeProviderFileSource
    private let processCommands: () -> [String]
    private let now: () -> Date

    init(
        homeDirectory: URL,
        fallbackProject: String,
        fileSource: NativeProviderFileSource = NativeProviderFileSource(),
        processCommands: @escaping () -> [String] = NativeSystemProcessSource.commands,
        now: @escaping () -> Date = Date.init
    ) {
        self.homeDirectory = homeDirectory
        self.fallbackProject = fallbackProject
        self.fileSource = fileSource
        self.processCommands = processCommands
        self.now = now
    }

    func observations() -> NativeProviderObservationPair {
        let commands = processCommands()
        let date = now()
        return NativeProviderObservationPair(
            codex: NativeProviderObservationEngine.observeCodex(
                sessions: fileSource.codexSessions(
                    root: homeDirectory.appendingPathComponent(".codex/sessions", isDirectory: true)
                ),
                online: NativeProviderObservationEngine.codexProcessRunning(commands: commands),
                fallbackProject: fallbackProject,
                now: date
            ),
            claude: NativeProviderObservationEngine.observeClaude(
                events: fileSource.claudeEvents(
                    root: homeDirectory.appendingPathComponent(".claude/projects", isDirectory: true)
                ),
                online: NativeProviderObservationEngine.claudeProcessRunning(commands: commands),
                project: fallbackProject,
                now: date
            )
        )
    }
}

struct NativeBridgeRuntimePaths {
    let supportDirectory: URL
    let homeDirectory: URL

    var identity: URL { supportDirectory.appendingPathComponent("bridge-identity-v1.json") }
    var registry: URL { supportDirectory.appendingPathComponent("devices-v1.json") }
    var deviceConfiguration: URL { supportDirectory.appendingPathComponent("device-config-v1.json") }
    var state: URL { supportDirectory.appendingPathComponent("state.json") }
    var codexQuota: URL { supportDirectory.appendingPathComponent("codex-quota.json") }
    var claudeQuota: URL { supportDirectory.appendingPathComponent("claude-quota.json") }
    var recording: URL { supportDirectory.appendingPathComponent("recording.json") }
    var pendingSend: URL { supportDirectory.appendingPathComponent("pending-send-v1.json") }
    var recordings: URL { supportDirectory.appendingPathComponent("recordings", isDirectory: true) }
    var hudState: URL { supportDirectory.appendingPathComponent("hud-state.json") }
    var pasteHelper: URL {
        supportDirectory.appendingPathComponent(
            "Components.noindex/VibeStick Paste.app",
            isDirectory: true
        )
    }
}

final class NativeBridgeRuntimeStore: NativeBridgeRoutingStore {
    static let version = "0.2.0"
    static let manualStatusSeconds: TimeInterval = 60
    static let deviceOnlineSeconds: TimeInterval = 10
    static let quotaStaleSeconds: TimeInterval = 30 * 60

    let bridgeID: String
    let bridgeVersion: String
    let bridgeToken: String

    private let registry: NativePairedDeviceRegistry
    private let deviceConfiguration: NativeDeviceConfigurationStore
    private let stateDocument: NativeBridgeStateDocument
    private let quotaStore: NativeQuotaStore
    private let claudeQuotaStore: NativeQuotaStore
    private let voice: NativeVoiceRecordingController
    private let observeProviders: () -> NativeProviderObservationPair
    private let fetchAccountQuota: () -> NativeQuotaSnapshot?
    private let fetchClaudeQuota: () -> NativeQuotaSnapshot?
    private let now: () -> Date
    private let lock = NSRecursiveLock()
    private let configuredProvider: String
    private let claudeUsageEnabled: Bool
    private let claudeUsageInterval: TimeInterval

    private var state: NativeBridgeStateModel
    private var codexQuota: NativeQuotaSnapshot
    private var claudeQuota: NativeQuotaSnapshot
    private var lastActiveProvider: String
    private var manualStatusUntil: TimeInterval = 0
    private var deviceRuntime: [String: NativeDeviceRuntime] = [:]
    private var lastClaudeAttemptEpoch: TimeInterval = 0

    init(
        bridgeID: String,
        bridgeToken: String,
        configuredProvider: String,
        registry: NativePairedDeviceRegistry,
        deviceConfiguration: NativeDeviceConfigurationStore,
        stateDocument: NativeBridgeStateDocument,
        quotaStore: NativeQuotaStore,
        claudeQuotaStore: NativeQuotaStore,
        voice: NativeVoiceRecordingController,
        observeProviders: @escaping () -> NativeProviderObservationPair,
        fetchAccountQuota: @escaping () -> NativeQuotaSnapshot? = { nil },
        fetchClaudeQuota: @escaping () -> NativeQuotaSnapshot? = { nil },
        claudeUsageEnabled: Bool = false,
        claudeUsageInterval: TimeInterval = 300,
        now: @escaping () -> Date = Date.init,
        bridgeVersion: String = NativeBridgeRuntimeStore.version
    ) {
        self.bridgeID = bridgeID
        self.bridgeVersion = bridgeVersion
        self.bridgeToken = NativeBridgeSecurity.normalizedBridgeToken(bridgeToken)
        self.configuredProvider = ["codex", "claude", "auto"].contains(configuredProvider)
            ? configuredProvider : "auto"
        self.registry = registry
        self.deviceConfiguration = deviceConfiguration
        self.stateDocument = stateDocument
        self.quotaStore = quotaStore
        self.claudeQuotaStore = claudeQuotaStore
        self.voice = voice
        self.observeProviders = observeProviders
        self.fetchAccountQuota = fetchAccountQuota
        self.fetchClaudeQuota = fetchClaudeQuota
        self.claudeUsageEnabled = claudeUsageEnabled
        self.claudeUsageInterval = max(30, claudeUsageInterval)
        self.now = now
        self.state = stateDocument.load()
        self.codexQuota = quotaStore.load()
        self.claudeQuota = claudeQuotaStore.load()
        if !self.claudeQuota.hasQuota,
           self.state.provider.id == "claude",
           self.state.provider.quota5HRemaining != nil || self.state.provider.quota7DRemaining != nil {
            self.claudeQuota = NativeQuotaSnapshot(
                quota5HRemaining: self.state.provider.quota5HRemaining,
                quota7DRemaining: self.state.provider.quota7DRemaining,
                quotaUpdatedAt: self.state.provider.quotaUpdatedAt,
                quotaStale: true,
                quotaSource: "legacy-state"
            )
        }
        self.lastActiveProvider = ["codex", "claude"].contains(self.state.activeProvider)
            ? self.state.activeProvider : "codex"
        applyQuotaToState(self.codexQuota)
    }

    func authenticateDevice(id: String, token: String) -> Bool {
        registry.authenticate(deviceID: id, token: token)
    }

    func noteDeviceRequest(id: String, headers: [String: String]) {
        withLock {
            var runtime = deviceRuntime[id] ?? NativeDeviceRuntime()
            runtime.lastSeenEpoch = finiteEpoch(now().timeIntervalSince1970)
            runtime.firmwareName = String(header("X-Vibe-Stick-Firmware-Name", in: headers).prefix(32))
            runtime.firmwareVersion = String(header("X-Vibe-Stick-Firmware-Version", in: headers).prefix(32))
            deviceRuntime[id] = runtime
        }
    }

    func currentState() -> [String: Any] {
        withLock {
            refreshProvidersLocked()
            saveStateLocked()
            return state.json(now: now())
        }
    }

    func devicesStatus() -> [String: Any] {
        withLock {
            let timestamp = finiteEpoch(now().timeIntervalSince1970)
            let revision = currentConfigurationRevision()
            let devices: [[String: Any]] = registry.devices().map { paired in
                let runtime = deviceRuntime[paired.deviceID]
                let lastSeen = runtime?.lastSeenEpoch
                let online = lastSeen.map { timestamp >= $0 && timestamp - $0 <= Self.deviceOnlineSeconds } ?? false
                return [
                    "device_id": paired.deviceID,
                    "name": paired.name,
                    "paired_at": paired.pairedAt,
                    "firmware_version": runtime?.firmwareVersion.isEmpty == false
                        ? runtime!.firmwareVersion : paired.firmwareVersion,
                    "online": online,
                    "last_seen_epoch": lastSeen.map { $0 as Any } ?? NSNull(),
                    "last_config_revision": runtime?.lastConfigurationRevision.map { $0 as Any } ?? NSNull(),
                    "target_config_revision": revision,
                    "revoked": paired.revoked,
                ]
            }
            return [
                "bridge_id": bridgeID,
                "protocol_version": 2,
                "devices": devices,
            ]
        }
    }

    func currentDeviceConfiguration() -> [String: Any] {
        deviceConfiguration.current()
    }

    func acknowledgeConfiguration(deviceID: String, revision: Int) -> [String: Any] {
        withLock {
            let current = currentConfigurationRevision()
            let accepted = revision == current
            var runtime = deviceRuntime[deviceID] ?? NativeDeviceRuntime()
            runtime.lastSeenEpoch = finiteEpoch(now().timeIntervalSince1970)
            if accepted { runtime.lastConfigurationRevision = revision }
            deviceRuntime[deviceID] = runtime
            return ["accepted": accepted, "current_revision": current]
        }
    }

    func update(event: [String: Any]) -> [String: Any] {
        withLock {
            let eventName = event["event"] as? String ?? ""
            if let requested = event["codex_status"] as? String
                ?? event["status"] as? String,
               !requested.isEmpty {
                setManualCodexStatusLocked(
                    requested,
                    message: event["message"] as? String ?? ""
                )
                manualStatusUntil = finiteEpoch(now().timeIntervalSince1970) + Self.manualStatusSeconds
            } else if eventName == "button_double" {
                refreshQuotaLocked()
            } else if eventName == "button_short" {
                state.alert = NativeAlertState()
            }
            refreshProvidersLocked()
            saveStateLocked()
            return state.json(now: now())
        }
    }

    func refreshQuota() -> [String: Any] {
        withLock {
            refreshQuotaLocked()
            refreshProvidersLocked()
            saveStateLocked()
            return state.json(now: now())
        }
    }

    func startRecording(request: [String: Any]) -> [String: Any] {
        withLock {
            state.alert = NativeAlertState()
            saveStateLocked()
        }
        return voiceResponse(voice.start(request: request))
    }

    func attachRecordingAudio(
        _ data: Data,
        sessionID: String,
        sampleRate: Int,
        channels: Int,
        bitsPerSample: Int
    ) -> [String: Any] {
        voiceResponse(voice.attachPCM(
            data,
            sessionID: sessionID,
            sampleRate: sampleRate,
            channels: channels,
            bitsPerSample: bitsPerSample
        ))
    }

    func stopRecording(request: [String: Any]) -> [String: Any] {
        voiceResponse(voice.stop(request: request))
    }

    func confirmRecordingSend(request: [String: Any]) -> [String: Any] {
        voiceResponse(voice.confirmSend(request: request))
    }

    private func voiceResponse(_ payload: [String: Any]) -> [String: Any] {
        var result = payload
        result["state"] = currentState()
        return result
    }

    private func refreshProvidersLocked() {
        var pair = observeProviders()
        pair.codex.quota = preferredCodexQuota(pair.codex.quota)
        let timestamp = finiteEpoch(now().timeIntervalSince1970)
        if timestamp < manualStatusUntil {
            pair.codex.status = state.codex.status
            pair.codex.alertType = state.alert.type
            pair.codex.alertMessage = state.alert.message
            pair.codex.alertEventID = state.alert.eventID
        }
        let activeProvider = NativeProviderObservationEngine.selectActiveProvider(
            configured: configuredProvider,
            lastActive: lastActiveProvider,
            codex: pair.codex,
            claude: pair.claude
        )
        if activeProvider == "claude" {
            refreshClaudeQuotaLocked(force: false)
            pair.claude.quota = currentClaudeQuota()
        }
        lastActiveProvider = activeProvider
        state.activeProvider = activeProvider
        state.codex = pair.codex.agentState
        let active = activeProvider == "claude" ? pair.claude : pair.codex
        state.provider = active.agentState
        let alert = NativeProviderObservationEngine.selectAlert(
            active: active,
            codex: pair.codex,
            claude: pair.claude
        )
        state.alert = alert.hasAlert
            ? NativeAlertState(
                eventID: alert.alertEventID,
                type: alert.alertType,
                message: alert.alertMessage
            )
            : NativeAlertState()
    }

    private func preferredCodexQuota(_ candidate: NativeQuotaSnapshot) -> NativeQuotaSnapshot {
        if candidate.hasQuota,
           !codexQuota.hasQuota
            || candidate.quotaObservedAtEpoch > codexQuota.quotaObservedAtEpoch
            || candidate.quotaObservedAtEpoch == codexQuota.quotaObservedAtEpoch
                && candidate.quotaSource == "codex-app-server"
                && codexQuota.quotaSource != "codex-app-server" {
            codexQuota = candidate
            try? quotaStore.save(candidate)
        }
        return codexQuota.staleIfOlder(than: Self.quotaStaleSeconds, now: now())
    }

    private func refreshQuotaLocked() {
        if state.activeProvider == "claude" {
            refreshClaudeQuotaLocked(force: true)
            return
        }
        if let refreshed = fetchAccountQuota(), refreshed.hasQuota {
            _ = preferredCodexQuota(refreshed)
        }
    }

    private func refreshClaudeQuotaLocked(force: Bool) {
        guard claudeUsageEnabled else { return }
        let timestamp = finiteEpoch(now().timeIntervalSince1970)
        guard force || timestamp - lastClaudeAttemptEpoch >= claudeUsageInterval else { return }
        lastClaudeAttemptEpoch = timestamp
        guard let refreshed = fetchClaudeQuota(), refreshed.hasQuota else {
            if claudeQuota.hasQuota {
                claudeQuota.quotaStale = true
                try? claudeQuotaStore.save(claudeQuota)
            }
            return
        }
        claudeQuota = refreshed
        try? claudeQuotaStore.save(refreshed)
    }

    private func currentClaudeQuota() -> NativeQuotaSnapshot {
        claudeQuota.staleIfOlder(than: Self.quotaStaleSeconds, now: now())
    }

    private func applyQuotaToState(_ quota: NativeQuotaSnapshot) {
        state.codex.quota5HRemaining = quota.quota5HRemaining
        state.codex.quota7DRemaining = quota.quota7DRemaining
        state.codex.quotaUpdatedAt = quota.quotaUpdatedAt
        state.codex.quotaStale = quota.quotaStale
        if state.activeProvider == "codex" {
            state.provider.quota5HRemaining = quota.quota5HRemaining
            state.provider.quota7DRemaining = quota.quota7DRemaining
            state.provider.quotaUpdatedAt = quota.quotaUpdatedAt
            state.provider.quotaStale = quota.quotaStale
        }
    }

    private func setManualCodexStatusLocked(_ raw: String, message: String) {
        let status = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        state.codex.status = NativeAgentState.validStatuses.contains(status) ? status : "UNKNOWN"
        if state.activeProvider == "codex" { state.provider.status = state.codex.status }
        let eventID = "evt_\(eventTimestamp())"
        switch state.codex.status {
        case "DONE":
            state.alert = NativeAlertState(
                eventID: eventID + "_done",
                type: "DONE",
                message: message.isEmpty ? "Codex task completed" : message
            )
        case "APPROVAL":
            state.alert = NativeAlertState(
                eventID: eventID + "_approval",
                type: "APPROVAL",
                message: message.isEmpty ? "Codex is waiting for approval" : message
            )
        case "ERROR":
            state.alert = NativeAlertState(
                eventID: eventID + "_error",
                type: "ERROR",
                message: message.isEmpty ? "Codex needs attention" : message
            )
        default:
            state.alert = NativeAlertState()
        }
    }

    private func currentConfigurationRevision() -> Int {
        let raw = deviceConfiguration.current()["revision"] as? NSNumber
        guard let raw, CFGetTypeID(raw) != CFBooleanGetTypeID() else { return 0 }
        return max(0, raw.intValue)
    }

    private func saveStateLocked() {
        try? stateDocument.save(state, now: now())
    }

    private func eventTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: now())
    }

    private func withLock<T>(_ operation: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }

    private func header(_ name: String, in headers: [String: String]) -> String {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value ?? ""
    }

    private func finiteEpoch(_ raw: TimeInterval) -> TimeInterval {
        raw.isFinite && raw >= 0 ? raw : 0
    }
}

private struct NativeDeviceRuntime {
    var lastSeenEpoch: TimeInterval?
    var firmwareName = ""
    var firmwareVersion = ""
    var lastConfigurationRevision: Int?
}
