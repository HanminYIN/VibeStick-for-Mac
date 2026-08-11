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

    enum CodingKeys: String, CodingKey {
        case ok
        case bridgeName = "bridge_name"
        case bridgeVersion = "bridge_version"
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

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case status
        case project
        case quota5HRemaining = "quota_5h_remaining"
        case quota7DRemaining = "quota_7d_remaining"
        case quotaUpdatedAt = "quota_updated_at"
        case quotaStale = "quota_stale"
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
}

struct LegacyConfigurationSummary: Equatable, Sendable {
    let legacyFileExists: Bool
    let asrConfigurationDetected: Bool
    let asrProvider: String?
    let autoEnterEnabled: Bool
    let projectName: String?
    let containsLegacySecrets: Bool
    let legacyFileIsOverexposed: Bool

    static let empty = LegacyConfigurationSummary(
        legacyFileExists: false,
        asrConfigurationDetected: false,
        asrProvider: nil,
        autoEnterEnabled: false,
        projectName: nil,
        containsLegacySecrets: false,
        legacyFileIsOverexposed: false
    )
}

struct KeychainSummary: Equatable, Sendable {
    let bridgeTokenStored: Bool
    let asrKeyStored: Bool

    static let empty = KeychainSummary(
        bridgeTokenStored: false,
        asrKeyStored: false
    )
}

struct ConfigurationInspection: Equatable, Sendable {
    let legacy: LegacyConfigurationSummary
    let keychain: KeychainSummary
}

struct AppConfiguration: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var showMenuBarItem: Bool
    var launchAtLogin: Bool
    var showTechnicalDetails: Bool
    var refreshIntervalSeconds: Double

    static let standard = AppConfiguration(
        schemaVersion: currentSchemaVersion,
        showMenuBarItem: true,
        launchAtLogin: false,
        showTechnicalDetails: false,
        refreshIntervalSeconds: 15
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
