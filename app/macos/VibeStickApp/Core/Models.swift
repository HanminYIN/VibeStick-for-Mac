import Foundation
import SwiftUI

enum AppPreferenceKey {
    static let showMenuBarItem = "showMenuBarItem"
}

enum AppSection: String, CaseIterable, Codable, Identifiable, Sendable {
    case overview
    case deviceInterface
    case voice
    case buttons
    case connection
    case updates
    case advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "首页"
        case .deviceInterface: "设备界面"
        case .voice: "语音与发送"
        case .buttons: "按键与提醒"
        case .connection: "连接与后台"
        case .updates: "更新与恢复"
        case .advanced: "高级设置"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .deviceInterface: "display"
        case .voice: "waveform"
        case .buttons: "button.programmable"
        case .connection: "point.3.connected.trianglepath.dotted"
        case .updates: "arrow.triangle.2.circlepath"
        case .advanced: "slider.horizontal.3"
        }
    }
}

enum HealthTone: String, Codable, Sendable {
    case healthy
    case warning
    case inactive
    case neutral

    var color: Color {
        switch self {
        case .healthy: .green
        case .warning: .orange
        case .inactive: .secondary
        case .neutral: VibeStickStyle.accent
        }
    }
}

enum ServicePhase: String, Codable, Sendable {
    case notInstalled
    case stopped
    case starting
    case healthy
    case runningNotReady
    case permissionMissing
    case versionMismatch
    case portConflict
    case needsRepair
    case unknown

    var label: String {
        switch self {
        case .notInstalled: "未安装"
        case .stopped: "已停止"
        case .starting: "正在启动"
        case .healthy: "正常"
        case .runningNotReady: "运行但未就绪"
        case .permissionMissing: "需要权限"
        case .versionMismatch: "版本不匹配"
        case .portConflict: "端口冲突"
        case .needsRepair: "需要修复"
        case .unknown: "正在检查"
        }
    }

    var tone: HealthTone {
        switch self {
        case .healthy: .healthy
        case .permissionMissing, .versionMismatch, .portConflict, .needsRepair, .runningNotReady: .warning
        case .notInstalled, .stopped: .inactive
        case .starting, .unknown: .neutral
        }
    }
}

enum ComponentKind: String, Codable, Sendable {
    case bridge
    case hud
    case paste

    var title: String {
        switch self {
        case .bridge: "设备连接服务"
        case .hud: "屏幕提示服务"
        case .paste: "文字输入服务"
        }
    }

    var technicalName: String {
        switch self {
        case .bridge: "VibeStick Bridge / com.vibestick.bridge"
        case .hud: "VibeStick HUD / com.vibestick.hud"
        case .paste: "VibeStick Paste / com.vibestick.paste"
        }
    }

    var systemImage: String {
        switch self {
        case .bridge: "point.3.connected.trianglepath.dotted"
        case .hud: "rectangle.on.rectangle"
        case .paste: "text.cursor"
        }
    }
}

enum RuntimeOwnership: String, Codable, Sendable {
    case legacyLaunchAgent
    case externalProcess
    case conflictingProcess
    case none
}

struct ComponentHealth: Identifiable, Equatable, Sendable {
    let kind: ComponentKind
    let phase: ServicePhase
    let detail: String
    let isInstalled: Bool
    let ownership: RuntimeOwnership

    init(
        kind: ComponentKind,
        phase: ServicePhase,
        detail: String,
        isInstalled: Bool,
        ownership: RuntimeOwnership = .legacyLaunchAgent
    ) {
        self.kind = kind
        self.phase = phase
        self.detail = detail
        self.isInstalled = isInstalled
        self.ownership = ownership
    }

    var id: String { kind.rawValue }
}

struct RuntimeSnapshot: Equatable, Sendable {
    let bridge: ComponentHealth
    let hud: ComponentHealth
    let paste: ComponentHealth
    let isRecordingActive: Bool
    let checkedAt: Date

    static let waiting = RuntimeSnapshot(
        bridge: ComponentHealth(
            kind: .bridge,
            phase: .unknown,
            detail: "正在检查现有服务",
            isInstalled: false,
            ownership: .none
        ),
        hud: ComponentHealth(
            kind: .hud,
            phase: .unknown,
            detail: "正在检查现有服务",
            isInstalled: false,
            ownership: .none
        ),
        paste: ComponentHealth(
            kind: .paste,
            phase: .unknown,
            detail: "正在检查权限",
            isInstalled: false,
            ownership: .none
        ),
        isRecordingActive: false,
        checkedAt: .distantPast
    )

    var overallTone: HealthTone {
        let phases = [bridge.phase, hud.phase, paste.phase]
        if phases.allSatisfy({ $0 == .healthy }) { return .healthy }
        if phases.contains(where: {
            [.permissionMissing, .needsRepair, .runningNotReady, .versionMismatch, .portConflict].contains($0)
        }) {
            return .warning
        }
        return .inactive
    }
}

struct BridgeHealthDTO: Decodable, Equatable, Sendable {
    let ok: Bool
    let bridgeName: String
    let bridgeVersion: String
    let protocolVersion: Int?
    let voiceInteractionVersion: Int?
    let bridgeID: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case bridgeName = "bridge_name"
        case bridgeVersion = "bridge_version"
        case protocolVersion = "protocol_version"
        case voiceInteractionVersion = "voice_interaction_version"
        case bridgeID = "bridge_id"
    }
}

struct QuotaWindowDTO: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let label: String
    let remainingPercent: Double?
    let updatedAt: String?
    let stale: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case label
        case remainingPercent = "remaining_percent"
        case updatedAt = "updated_at"
        case stale
    }
}

struct AgentStateDTO: Decodable, Equatable, Sendable {
    let id: String?
    let displayName: String?
    let status: String
    let project: String?
    let quota5HRemaining: Double?
    let quota7DRemaining: Double?
    let quotaUpdatedAt: String?
    let quotaStale: Bool?
    let quotaWindows: [QuotaWindowDTO]?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case status
        case project
        case quota5HRemaining = "quota_5h_remaining"
        case quota7DRemaining = "quota_7d_remaining"
        case quotaUpdatedAt = "quota_updated_at"
        case quotaStale = "quota_stale"
        case quotaWindows = "quota_windows"
    }
}

struct BridgeStateDTO: Decodable, Equatable, Sendable {
    let time: String
    let wifi: Bool
    let battery: Double?
    let activeProvider: String
    let provider: AgentStateDTO
    let codex: AgentStateDTO?
    let bridgeName: String?
    let bridgeVersion: String?

    enum CodingKeys: String, CodingKey {
        case time
        case wifi
        case battery
        case activeProvider = "active_provider"
        case provider
        case codex
        case bridgeName = "bridge_name"
        case bridgeVersion = "bridge_version"
    }

    var codexState: AgentStateDTO? {
        codex ?? (activeProvider == "codex" ? provider : nil)
    }
}

struct BridgeSnapshot: Equatable, Sendable {
    let health: BridgeHealthDTO?
    let state: BridgeStateDTO?
    let healthEndpointResponded: Bool
    let errorMessage: String?
    let checkedAt: Date

    static let empty = BridgeSnapshot(
        health: nil,
        state: nil,
        healthEndpointResponded: false,
        errorMessage: nil,
        checkedAt: .distantPast
    )

    var isHealthy: Bool {
        health?.ok == true && health?.bridgeName == "vibestick-bridge"
    }

    var hasPortConflict: Bool {
        healthEndpointResponded && !isHealthy
    }

    var isM2PairingReady: Bool {
        isHealthy && health?.protocolVersion == 2 && health?.bridgeID.flatMap(UUID.init(uuidString:)) != nil
    }
}

enum CodexFocusPreviewStatusTone: Equatable, Sendable {
    case accent
    case approval
    case neutral
    case dim
}

struct CodexFocusPreviewQuotaWindow: Equatable, Sendable {
    let id: String
    let label: String
    let remainingPercent: Int?
    let stale: Bool
}

struct CodexFocusPreviewModel: Equatable, Sendable {
    let wifiConnected: Bool
    let bridgeConnected: Bool
    let batteryPercent: Int?
    let statusKey: String
    let statusText: String
    let statusTone: CodexFocusPreviewStatusTone
    let project: String?
    let quotaWindows: [CodexFocusPreviewQuotaWindow]
    let syncHealthy: Bool
    let footerAction: String

    var batteryText: String {
        batteryPercent.map { "\($0)%" } ?? "--%"
    }

    static func make(
        bridge: BridgeSnapshot,
        devices: BridgeDevicesDTO?,
        configuration: DeviceConfiguration
    ) -> CodexFocusPreviewModel {
        let device = devices?.devices.first(where: { !$0.revoked })
        let deviceOnline = device?.online == true
        let bridgeConnected = bridge.isHealthy && deviceOnline
        let codex = bridge.state?.codexState
        let statusKey = normalizedStatus(
            bridgeConnected ? codex?.status : "OFFLINE"
        )
        let fixedProject = configuration.project.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let liveProject = codex?.project?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let selectedProject = fixedProject.isEmpty ? liveProject : fixedProject
        let project = configuration.project.visible && !selectedProject.isEmpty ? selectedProject : nil
        let quotaWindows = normalizedQuotaWindows(codex)
        let quotaStale = quotaWindows.contains(where: \CodexFocusPreviewQuotaWindow.stale)
            || codex?.quotaStale == true
        let configurationSynced = device.map {
            $0.lastConfigRevision == $0.targetConfigRevision
        } ?? false

        return CodexFocusPreviewModel(
            wifiConnected: deviceOnline && bridge.state?.wifi == true,
            bridgeConnected: bridgeConnected,
            batteryPercent: normalizedPercent(bridge.state?.battery),
            statusKey: statusKey,
            statusText: statusText(for: statusKey),
            statusTone: statusTone(for: statusKey),
            project: project,
            quotaWindows: quotaWindows,
            syncHealthy: bridgeConnected && configurationSynced && !quotaStale,
            footerAction: footerAction(for: configuration.buttons.frontDouble)
        )
    }

    private static func normalizedStatus(_ value: String?) -> String {
        let key = value?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? "UNKNOWN"
        switch key {
        case "RUNNING", "DONE", "APPROVAL", "ERROR", "OFFLINE", "IDLE", "UNKNOWN":
            return key
        default:
            return "UNKNOWN"
        }
    }

    private static func statusText(for key: String) -> String {
        switch key {
        case "RUNNING": "运行中"
        case "DONE": "已完成"
        case "APPROVAL": "待确认"
        case "ERROR": "出错"
        case "OFFLINE": "离线"
        default: "待命"
        }
    }

    private static func statusTone(for key: String) -> CodexFocusPreviewStatusTone {
        switch key {
        case "RUNNING", "DONE": .accent
        case "APPROVAL": .approval
        case "ERROR", "OFFLINE": .dim
        default: .neutral
        }
    }

    private static func normalizedQuotaWindows(_ codex: AgentStateDTO?) -> [CodexFocusPreviewQuotaWindow] {
        if let windows = codex?.quotaWindows, !windows.isEmpty {
            return windows.prefix(2).map {
                CodexFocusPreviewQuotaWindow(
                    id: $0.id,
                    label: normalizedQuotaLabel($0.label, fallback: $0.id.uppercased()),
                    remainingPercent: normalizedPercent($0.remainingPercent),
                    stale: $0.stale || codex?.quotaStale == true
                )
            }
        }

        var windows: [CodexFocusPreviewQuotaWindow] = []
        if let value = normalizedPercent(codex?.quota5HRemaining) {
            windows.append(.init(id: "5h", label: "5H", remainingPercent: value, stale: codex?.quotaStale == true))
        }
        if let value = normalizedPercent(codex?.quota7DRemaining) {
            windows.append(.init(id: "7d", label: "7D", remainingPercent: value, stale: codex?.quotaStale == true))
        }
        return windows
    }

    private static func normalizedQuotaLabel(_ value: String, fallback: String) -> String {
        let label = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((label.isEmpty ? fallback : label).prefix(8))
    }

    private static func normalizedPercent(_ value: Double?) -> Int? {
        guard let value, value.isFinite else { return nil }
        return min(100, max(0, Int(value.rounded())))
    }

    private static func footerAction(for action: FrontDoublePressAction) -> String {
        switch action {
        case .refreshQuota: "2X REFRESH"
        case .showStatus: "2X STATUS"
        case .home: "2X HOME"
        case .toggleMute: "2X MUTE"
        }
    }
}

enum VoiceSendMode: String, Equatable, Sendable {
    case pasteOnly = "paste_only"
    case confirm
    case autoSend = "auto_send"

    static func configured(explicit: String?, autoEnterEnabled: Bool) -> VoiceSendMode {
        let value = explicit?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
        return switch value {
        case "paste", "paste_only": .pasteOnly
        case "confirm", "blue_button": .confirm
        case "auto", "auto_send": .autoSend
        default: autoEnterEnabled ? .autoSend : .pasteOnly
        }
    }

    var title: String {
        switch self {
        case .pasteOnly: "仅粘贴"
        case .confirm: "蓝键确认发送"
        case .autoSend: "自动发送"
        }
    }

    var detail: String {
        switch self {
        case .pasteOnly: "转写后只粘贴文字，不按 Return"
        case .confirm: "先粘贴；只有目标输入框仍匹配时，蓝键才发送"
        case .autoSend: "一次操作内粘贴并按 Return；仅在明确启用时生效"
        }
    }
}

struct VoiceInteractionSummary: Equatable, Sendable {
    let status: String
    let pasted: Bool
    let interactionVersion: Int
    let sendMode: VoiceSendMode
    let stoppedAt: String?

    static let empty = VoiceInteractionSummary(
        status: "idle",
        pasted: false,
        interactionVersion: 1,
        sendMode: .pasteOnly,
        stoppedAt: nil
    )

    var title: String {
        switch status {
        case "recording": "正在聆听"
        case "transcribing": "正在识别"
        case "pending_send": "等待蓝键确认"
        case "sent": "已发送"
        case "pasted": "已粘贴"
        case "copied", "transcribed": "已识别，未发送"
        case "audio_skipped", "transcript_rejected": "未听清"
        case "transcription_failed": "识别失败"
        case "confirmation_unavailable", "send_failed": "安全停止：未发送"
        case "paste_failed": "文字输入失败"
        case "start_failed", "stop_failed", "audio_failed": "语音操作未完成"
        default: "尚无语音记录"
        }
    }

    var detail: String {
        switch status {
        case "pending_send": "文字已粘贴；会话只接受当前目标输入框的一次确认"
        case "sent": "Return 已发送到重新验证通过的原输入框"
        case "pasted": "文字已粘贴，未自动按 Return"
        case "copied", "transcribed": "文字保留在剪贴板或当前会话中，没有自动发送"
        case "confirmation_unavailable", "send_failed":
            pasted ? "文字已粘贴，但目标无法安全确认，因此没有按 Return" : "没有按 Return，也没有自动发送"
        case "audio_skipped", "transcript_rejected": "没有把不清晰或不可信的识别结果输入到 Mac"
        case "transcription_failed": "识别没有产生可用文字"
        case "paste_failed": "识别可能成功，但文字没有可靠输入到当前目标"
        case "recording", "transcribing": "设备语音会话正在进行"
        default: "完成一次设备语音操作后，这里只显示脱敏结果摘要"
        }
    }

    var tone: HealthTone {
        switch status {
        case "sent", "pasted", "copied", "transcribed": .healthy
        case "recording", "transcribing", "pending_send": .neutral
        case "audio_skipped", "transcript_rejected", "transcription_failed",
             "confirmation_unavailable", "send_failed", "paste_failed",
             "start_failed", "stop_failed", "audio_failed": .warning
        default: .inactive
        }
    }
}

struct LegacyConfigurationSummary: Equatable, Sendable {
    let legacyFileExists: Bool
    let asrConfigurationDetected: Bool
    let asrProvider: String?
    let autoEnterEnabled: Bool
    let voiceSendMode: VoiceSendMode
    let projectName: String?
    let containsLegacySecrets: Bool
    let legacyFileIsOverexposed: Bool

    static let empty = LegacyConfigurationSummary(
        legacyFileExists: false,
        asrConfigurationDetected: false,
        asrProvider: nil,
        autoEnterEnabled: false,
        voiceSendMode: .pasteOnly,
        projectName: nil,
        containsLegacySecrets: false,
        legacyFileIsOverexposed: false
    )
}

struct LegacyKeychainSummary: Equatable, Sendable {
    let bridgeTokenStored: Bool
    let asrKeyStored: Bool

    static let empty = LegacyKeychainSummary(
        bridgeTokenStored: false,
        asrKeyStored: false
    )
}

enum M4ManagedRuntimeConfigurationState: Equatable, Sendable {
    case notConfigured
    case validated
    case invalid
    case unavailable
}

enum M4ManagedCredentialState: Equatable, Sendable {
    case notReferenced
    case stored
    case missing
    case unavailable
}

struct M4ManagedRuntimeSummary: Equatable, Sendable {
    let configurationState: M4ManagedRuntimeConfigurationState
    let bridgeCredentialState: M4ManagedCredentialState
    let asrCredentialState: M4ManagedCredentialState

    static let empty = M4ManagedRuntimeSummary(
        configurationState: .notConfigured,
        bridgeCredentialState: .notReferenced,
        asrCredentialState: .notReferenced
    )

    var hasStoredReferencedCredentials: Bool {
        let states = [bridgeCredentialState, asrCredentialState]
            .filter { $0 != .notReferenced }
        return !states.isEmpty && states.allSatisfy { $0 == .stored }
    }

    var requiresAttention: Bool {
        switch configurationState {
        case .invalid, .unavailable:
            return true
        case .notConfigured:
            return false
        case .validated:
            return [bridgeCredentialState, asrCredentialState].contains {
                $0 == .missing || $0 == .unavailable
            }
        }
    }
}

struct ConfigurationInspection: Equatable, Sendable {
    let legacy: LegacyConfigurationSummary
    let legacyKeychain: LegacyKeychainSummary
    let voice: VoiceInteractionSummary
}

enum ASRProvider: String, CaseIterable, Codable, Identifiable, Sendable {
    case siliconFlow = "siliconflow"
    case groq
    case openAICompatible = "openai-compatible"
    case localCommand = "local-command"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .siliconFlow: "硅基流动"
        case .groq: "Groq"
        case .openAICompatible: "OpenAI-compatible"
        case .localCommand: "本地命令"
        }
    }

    var detail: String {
        switch self {
        case .siliconFlow: "SenseVoiceSmall · 中国区 API"
        case .groq: "Whisper Large V3 Turbo"
        case .openAICompatible: "OpenAI 预设，可编辑为兼容端点"
        case .localCommand: "音频保留在 Mac，由自定义命令处理"
        }
    }

    var isCloud: Bool { self != .localCommand }

    static func fromLegacyID(_ value: String?) -> ASRProvider? {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "siliconflow", "silicon-flow": .siliconFlow
        case "groq": .groq
        case "openai", "openai-compatible": .openAICompatible
        case "command", "local-command": .localCommand
        default: nil
        }
    }
}

struct ASRConfiguration: Codable, Equatable, Sendable {
    var provider: ASRProvider
    var baseURL: String
    var model: String
    var language: String
    var localCommand: String

    static let standard = preset(.groq)

    static func preset(_ provider: ASRProvider) -> ASRConfiguration {
        switch provider {
        case .siliconFlow:
            ASRConfiguration(
                provider: provider,
                baseURL: "https://api.siliconflow.cn/v1",
                model: "FunAudioLLM/SenseVoiceSmall",
                language: "zh",
                localCommand: ""
            )
        case .groq:
            ASRConfiguration(
                provider: provider,
                baseURL: "https://api.groq.com/openai/v1",
                model: "whisper-large-v3-turbo",
                language: "zh",
                localCommand: ""
            )
        case .openAICompatible:
            ASRConfiguration(
                provider: provider,
                baseURL: "https://api.openai.com/v1",
                model: "gpt-4o-mini-transcribe",
                language: "zh",
                localCommand: ""
            )
        case .localCommand:
            ASRConfiguration(
                provider: provider,
                baseURL: "",
                model: "",
                language: "zh",
                localCommand: ""
            )
        }
    }

    var normalized: ASRConfiguration {
        var value = self
        value.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        value.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        value.language = String(language.trimmingCharacters(in: .whitespacesAndNewlines).prefix(12))
        value.localCommand = localCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        return value
    }

    var transcriptionURL: URL? {
        guard provider.isCloud else { return nil }
        let cleaned = normalized.baseURL
        guard var components = URLComponents(string: cleaned), components.host != nil else { return nil }
        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !path.hasSuffix("audio/transcriptions") {
            components.path = "/" + ([path, "audio/transcriptions"].filter { !$0.isEmpty }.joined(separator: "/"))
        }
        return components.url
    }

    var targetHost: String? { transcriptionURL?.host(percentEncoded: false) }

    var requiresAPIKey: Bool {
        guard provider.isCloud else { return false }
        guard let host = targetHost?.lowercased() else { return true }
        return !["localhost", "127.0.0.1", "::1"].contains(host)
    }

    func validated() throws -> ASRConfiguration {
        let value = normalized
        if value.provider == .localCommand {
            guard !value.localCommand.isEmpty else { throw ASRConfigurationError.missingCommand }
            return value
        }
        guard !value.model.isEmpty else { throw ASRConfigurationError.missingModel }
        guard let url = value.transcriptionURL,
              let scheme = url.scheme?.lowercased(),
              let host = url.host(percentEncoded: false)?.lowercased() else {
            throw ASRConfigurationError.invalidURL
        }
        let loopback = ["localhost", "127.0.0.1", "::1"].contains(host)
        guard scheme == "https" || (scheme == "http" && loopback) else {
            throw ASRConfigurationError.insecureURL
        }
        return value
    }
}

enum ASRConfigurationError: LocalizedError, Equatable {
    case invalidURL
    case insecureURL
    case missingModel
    case missingCommand
    case missingAPIKey

    var errorDescription: String? {
        switch self {
        case .invalidURL: "请输入有效的 Base URL 或完整转写地址"
        case .insecureURL: "云端 ASR 必须使用 HTTPS；只有 localhost 可以使用 HTTP"
        case .missingModel: "请输入转写模型名称"
        case .missingCommand: "请输入本地转写命令"
        case .missingAPIKey: "请输入 API Key，或先把已有 Key 保存到钥匙串"
        }
    }
}

enum ASRTestPhase: String, Equatable, Sendable {
    case idle
    case testing
    case success
    case failure
}

struct ASRTestFeedback: Equatable, Sendable {
    let phase: ASRTestPhase
    let title: String
    let detail: String
    let transcriptPreview: String?

    static let idle = ASRTestFeedback(
        phase: .idle,
        title: "尚未测试",
        detail: "点击后会生成固定测试音频并比对转写；不访问麦克风，不会复制、粘贴或按 Return。",
        transcriptPreview: nil
    )

    static func failure(_ title: String, detail: String) -> ASRTestFeedback {
        ASRTestFeedback(phase: .failure, title: title, detail: detail, transcriptPreview: nil)
    }
}

struct AppConfiguration: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var showMenuBarItem: Bool
    var launchAtLogin: Bool
    var showTechnicalDetails: Bool
    var refreshIntervalSeconds: Double
    var manualBridgeAddress: String?
    var asr: ASRConfiguration?

    static let standard = AppConfiguration(
        schemaVersion: currentSchemaVersion,
        showMenuBarItem: true,
        launchAtLogin: false,
        showTechnicalDetails: false,
        refreshIntervalSeconds: 15,
        manualBridgeAddress: nil,
        asr: nil
    )
}

enum KeychainSecret: String, CaseIterable, Sendable {
    case bridgeToken = "bridge-token"
    case asrAPIKey = "asr-api-key"
}

enum ServiceAction: Sendable {
    case start
    case restart
    case stop
}

struct ServiceActionResult: Equatable, Sendable {
    let success: Bool
    let message: String
}

struct AppMessage: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

enum DeviceModule: String, CaseIterable, Codable, Identifiable, Sendable {
    case codex
    case claude
    case connection

    var id: String { rawValue }

    var title: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        case .connection: "连接状态"
        }
    }
}

enum FrontDoublePressAction: String, CaseIterable, Codable, Identifiable, Sendable {
    case refreshQuota = "refresh_quota"
    case showStatus = "show_status"
    case home
    case toggleMute = "toggle_mute"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .refreshQuota: "刷新额度"
        case .showStatus: "显示状态"
        case .home: "返回首页"
        case .toggleMute: "静音切换"
        }
    }
}

enum SidePressAction: String, CaseIterable, Codable, Identifiable, Sendable {
    case nextPage = "next_page"
    case none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nextPage: "切换下一页"
        case .none: "不执行动作"
        }
    }
}

struct DeviceProjectConfiguration: Codable, Equatable, Sendable {
    var visible: Bool
    var name: String
}

struct DeviceButtonConfiguration: Codable, Equatable, Sendable {
    var frontDouble: FrontDoublePressAction
    var sideSingle: SidePressAction

    enum CodingKeys: String, CodingKey {
        case frontDouble = "front_double"
        case sideSingle = "side_single"
    }
}

struct DeviceConfiguration: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    var schemaVersion: Int
    var revision: Int
    var modules: [DeviceModule]
    var defaultPage: DeviceModule
    var project: DeviceProjectConfiguration
    var buttons: DeviceButtonConfiguration

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case revision
        case modules
        case defaultPage = "default_page"
        case project
        case buttons
    }

    static let standard = DeviceConfiguration(
        schemaVersion: schemaVersion,
        revision: 0,
        modules: [.codex, .connection],
        defaultPage: .codex,
        project: DeviceProjectConfiguration(visible: true, name: ""),
        buttons: DeviceButtonConfiguration(frontDouble: .refreshQuota, sideSingle: .nextPage)
    )

    var normalized: DeviceConfiguration {
        var value = self
        value.schemaVersion = Self.schemaVersion
        value.revision = max(0, revision)
        value.project.name = String(project.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(18))
        while value.project.name.utf8.count > 39 {
            value.project.name.removeLast()
        }
        value.modules = Array(modules.reduce(into: [DeviceModule]()) { result, module in
            if !result.contains(module) { result.append(module) }
        })
        if !value.modules.contains(.codex) { value.modules.insert(.codex, at: 0) }
        if !value.modules.contains(.connection) { value.modules.append(.connection) }
        if !value.modules.contains(value.defaultPage) { value.defaultPage = .codex }
        return value
    }
}

struct USBDeviceCandidate: Equatable, Sendable {
    let portPath: String
    let serialNumber: String?
    let vendorID: Int
    let productID: Int

    static let esp32S3VendorID = 0x303A
    static let usbSerialJTAGProductID = 0x1001
}

struct DeviceIdentity: Codable, Equatable, Sendable {
    let deviceID: String
    let model: String
    let firmwareVersion: String
    let protocolVersion: Int
    let pairingID: String?
    let pairingSchemaVersion: Int?
    let wifiConfigured: Bool?

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case model
        case firmwareVersion = "firmware_version"
        case protocolVersion = "protocol_version"
        case pairingID = "pairing_id"
        case pairingSchemaVersion = "pairing_schema_version"
        case wifiConfigured = "wifi_configured"
    }
}

struct PairedDeviceRecord: Codable, Equatable, Identifiable, Sendable {
    let deviceID: String
    var name: String
    let tokenSalt: String
    let tokenHash: String
    var keychainAccount: String? = nil
    let pairedAt: String
    let firmwareVersion: String
    var revoked: Bool

    var id: String { deviceID }

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case name
        case tokenSalt = "token_salt"
        case tokenHash = "token_hash"
        case keychainAccount = "keychain_account"
        case pairedAt = "paired_at"
        case firmwareVersion = "firmware_version"
        case revoked
    }
}

struct PairedDeviceRegistryDocument: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var devices: [PairedDeviceRecord]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case devices
    }

    static let empty = PairedDeviceRegistryDocument(schemaVersion: 1, devices: [])
}

struct PairedDeviceStatusDTO: Decodable, Equatable, Identifiable, Sendable {
    let deviceID: String
    let name: String
    let pairedAt: String
    let firmwareVersion: String
    let online: Bool
    let lastSeenEpoch: Double?
    let lastConfigRevision: Int?
    let targetConfigRevision: Int
    let revoked: Bool

    var id: String { deviceID }

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case name
        case pairedAt = "paired_at"
        case firmwareVersion = "firmware_version"
        case online
        case lastSeenEpoch = "last_seen_epoch"
        case lastConfigRevision = "last_config_revision"
        case targetConfigRevision = "target_config_revision"
        case revoked
    }
}

struct BridgeDevicesDTO: Decodable, Equatable, Sendable {
    let bridgeID: String
    let protocolVersion: Int
    let devices: [PairedDeviceStatusDTO]

    enum CodingKeys: String, CodingKey {
        case bridgeID = "bridge_id"
        case protocolVersion = "protocol_version"
        case devices
    }
}

enum PairingPhase: Equatable, Sendable {
    case idle
    case detecting
    case ready(USBDeviceCandidate)
    case pairing
    case paired(DeviceIdentity)
    case unavailable(String)

    var label: String {
        switch self {
        case .idle: "尚未检查"
        case .detecting: "正在识别 USB"
        case .ready: "已连接 StickS3"
        case .pairing: "正在安全配对"
        case .paired: "配对完成"
        case .unavailable: "需要处理"
        }
    }
}
