import Foundation

enum ASRTestTranscriptComparator {
    static func normalized(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
            .lowercased()
    }

    static func matches(expected: String, actual: String) -> Bool {
        let expected = normalized(expected)
        let actual = normalized(actual)
        return !expected.isEmpty && (actual == expected || actual.contains(expected))
    }
}

enum LegacyEnvironmentParser {
    static func parse(_ contents: String) -> [String: String] {
        var values: [String: String] = [:]
        for rawLine in contents.split(whereSeparator: \Character.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if line.hasPrefix("export ") {
                line.removeFirst("export ".count)
            }
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }

            if value.count >= 2,
               let first = value.first,
               let last = value.last,
               (first == "\"" || first == "'"),
               first == last {
                value.removeFirst()
                value.removeLast()
            }
            values[key] = value
        }
        return values
    }
}

enum ServiceStateResolver {
    static func launchAgent(
        kind: ComponentKind,
        installed: Bool,
        loaded: Bool,
        running: Bool,
        ready: Bool?,
        detail: String? = nil
    ) -> ComponentHealth {
        guard installed else {
            return ComponentHealth(
                kind: kind,
                phase: .notInstalled,
                detail: "未找到现有安装",
                isInstalled: false,
                ownership: .none
            )
        }
        guard loaded else {
            return ComponentHealth(
                kind: kind,
                phase: .stopped,
                detail: "已安装，但当前没有运行",
                isInstalled: true
            )
        }
        guard running else {
            return ComponentHealth(
                kind: kind,
                phase: .needsRepair,
                detail: detail ?? "后台任务已载入，但进程当前没有运行",
                isInstalled: true
            )
        }
        if ready == false {
            return ComponentHealth(
                kind: kind,
                phase: .runningNotReady,
                detail: detail ?? "进程已运行，但服务尚未就绪",
                isInstalled: true
            )
        }
        return ComponentHealth(
            kind: kind,
            phase: .healthy,
            detail: detail ?? "运行正常",
            isInstalled: true
        )
    }
}

enum RuntimeMaintenancePhase: String, Equatable, Sendable {
    case checking
    case ready
    case installationRequired
    case repairRequired
    case permissionRequired
    case startRequired
    case blocked
}

enum RuntimeMaintenanceAction: String, Equatable, Sendable {
    case installBridge
    case installHUD
    case installPaste
    case repairBridge
    case repairHUD
    case repairPaste
    case grantPastePermission
    case startBridge
    case startHUD
    case waitForRecording
    case resolvePortConflict
    case preserveExternalBridge

    var title: String {
        switch self {
        case .installBridge: "安装设备连接服务"
        case .installHUD: "安装屏幕提示服务"
        case .installPaste: "安装文字输入服务"
        case .repairBridge: "修复设备连接服务"
        case .repairHUD: "修复屏幕提示服务"
        case .repairPaste: "修复文字输入服务"
        case .grantPastePermission: "在系统设置中开启文字输入权限"
        case .startBridge: "启动设备连接服务"
        case .startHUD: "启动屏幕提示服务"
        case .waitForRecording: "等待当前语音操作结束"
        case .resolvePortConflict: "先处理端口冲突或未知后台"
        case .preserveExternalBridge: "保留外部 Bridge，不自动接管"
        }
    }
}

struct RuntimeMaintenancePlan: Equatable, Sendable {
    let phase: RuntimeMaintenancePhase
    let actions: [RuntimeMaintenanceAction]

    var allowsPayloadInstall: Bool {
        switch phase {
        case .installationRequired, .repairRequired, .ready: true
        case .checking, .permissionRequired, .startRequired, .blocked: false
        }
    }

    var summary: String {
        switch phase {
        case .checking:
            "正在只读检查现有后台组件。"
        case .ready:
            "后台组件完整，无需安装或修复。"
        case .installationRequired:
            "发现缺失组件；M4-2 将先备份现状，再补齐安装。"
        case .repairRequired:
            "发现损坏、版本不匹配或未就绪组件；修复前必须保留可回退副本。"
        case .permissionRequired:
            "组件本身完整，只需由你在 macOS 系统设置中授权，不应重装。"
        case .startRequired:
            "组件已经安装，只需启动后台服务，不需要重新安装。"
        case .blocked:
            "当前状态不允许安全安装或修复；先完成下面的阻断项。"
        }
    }
}

enum RuntimeMaintenancePlanner {
    static func make(from snapshot: RuntimeSnapshot) -> RuntimeMaintenancePlan {
        let components = [snapshot.bridge, snapshot.hud, snapshot.paste]

        if snapshot.checkedAt == .distantPast || components.contains(where: {
            $0.phase == .unknown || $0.phase == .starting
        }) {
            return RuntimeMaintenancePlan(phase: .checking, actions: [])
        }
        if snapshot.isRecordingActive {
            return RuntimeMaintenancePlan(phase: .blocked, actions: [.waitForRecording])
        }
        if snapshot.bridge.ownership == .conflictingProcess
            || components.contains(where: { $0.phase == .portConflict }) {
            return RuntimeMaintenancePlan(phase: .blocked, actions: [.resolvePortConflict])
        }
        if snapshot.bridge.ownership == .externalProcess {
            return RuntimeMaintenancePlan(phase: .blocked, actions: [.preserveExternalBridge])
        }

        let missingActions = components.compactMap { component -> RuntimeMaintenanceAction? in
            guard !component.isInstalled || component.phase == .notInstalled else { return nil }
            switch component.kind {
            case .bridge: return .installBridge
            case .hud: return .installHUD
            case .paste: return .installPaste
            }
        }
        if !missingActions.isEmpty {
            return RuntimeMaintenancePlan(
                phase: .installationRequired,
                actions: missingActions
            )
        }

        let repairActions = components.compactMap { component -> RuntimeMaintenanceAction? in
            guard [.needsRepair, .versionMismatch, .runningNotReady].contains(component.phase) else {
                return nil
            }
            switch component.kind {
            case .bridge: return .repairBridge
            case .hud: return .repairHUD
            case .paste: return .repairPaste
            }
        }
        if !repairActions.isEmpty {
            return RuntimeMaintenancePlan(phase: .repairRequired, actions: repairActions)
        }

        if snapshot.paste.phase == .permissionMissing {
            return RuntimeMaintenancePlan(
                phase: .permissionRequired,
                actions: [.grantPastePermission]
            )
        }

        let startActions = components.compactMap { component -> RuntimeMaintenanceAction? in
            guard component.phase == .stopped else { return nil }
            switch component.kind {
            case .bridge: return .startBridge
            case .hud: return .startHUD
            case .paste: return nil
            }
        }
        if !startActions.isEmpty {
            return RuntimeMaintenancePlan(phase: .startRequired, actions: startActions)
        }

        return RuntimeMaintenancePlan(phase: .ready, actions: [])
    }
}

enum LaunchAgentStateParser {
    static func isRunning(_ launchctlOutput: String) -> Bool {
        launchctlOutput
            .split(whereSeparator: \Character.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .contains("state = running")
    }

    static func programPath(_ launchctlOutput: String) -> String? {
        for rawLine in launchctlOutput.split(whereSeparator: \Character.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let prefix = "program = "
            if line.hasPrefix(prefix) {
                let path = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
                return path.isEmpty ? nil : path
            }
        }
        return nil
    }
}

enum RecordingActivityResolver {
    static func shouldProtect(
        claimsActive: Bool,
        modifiedAt: Date?,
        bridgeProcessRunning: Bool,
        now: Date = Date(),
        maximumAge: TimeInterval = 10 * 60
    ) -> Bool {
        guard claimsActive,
              bridgeProcessRunning,
              let modifiedAt else {
            return false
        }
        let age = now.timeIntervalSince(modifiedAt)
        return age >= 0 && age < maximumAge
    }
}

struct PastePermissionProbeResponse: Decodable, Equatable {
    let success: Bool
    let message: String
}

struct PastePermissionProbeCommand: Equatable {
    let executable: String
    let arguments: [String]
}

enum PastePermissionProbeProtocol {
    static func launchCommand(
        appPath: String,
        requestPath: String,
        responsePath: String
    ) -> PastePermissionProbeCommand {
        PastePermissionProbeCommand(
            executable: "/usr/bin/open",
            arguments: [
                "-W",
                "-g",
                "-n",
                appPath,
                "--args",
                "--request",
                requestPath,
                "--response",
                responsePath,
            ]
        )
    }

    static func unregisterCommand(appPath: String) -> PastePermissionProbeCommand {
        PastePermissionProbeCommand(
            executable: "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
            arguments: ["-u", appPath]
        )
    }

    static func permission(from data: Data) -> Bool? {
        try? JSONDecoder().decode(PastePermissionProbeResponse.self, from: data).success
    }
}

enum USBDeviceDetectionParser {
    static func detect(ioregOutput: String, ports: [String]) -> USBDeviceCandidate? {
        let availablePorts = Set(ports.filter { $0.hasPrefix("/dev/cu.usbmodem") })
        var candidates: [USBDeviceCandidate] = []
        for rawBlock in ioregOutput.components(separatedBy: "+-o AppleUSBACMData").dropFirst() {
            guard rawBlock.contains("\"idVendor\" = 12346"),
                  rawBlock.contains("\"idProduct\" = 4097"),
                  let suffix = quotedValue(after: "IOTTYSuffix", in: rawBlock) else {
                continue
            }
            let port = "/dev/cu.usbmodem\(suffix)"
            guard availablePorts.contains(port) else { continue }
            candidates.append(
                USBDeviceCandidate(
                    portPath: port,
                    serialNumber: quotedValue(after: "USB Serial Number", in: rawBlock),
                    vendorID: USBDeviceCandidate.esp32S3VendorID,
                    productID: USBDeviceCandidate.usbSerialJTAGProductID
                )
            )
        }
        return candidates.sorted { $0.portPath < $1.portPath }.first
    }

    private static func quotedValue(after key: String, in text: String) -> String? {
        for line in text.split(whereSeparator: \Character.isNewline) where line.contains(key) {
            guard let equals = line.firstIndex(of: "=") else { continue }
            let value = line[line.index(after: equals)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if !value.isEmpty { return value }
        }
        return nil
    }
}

enum SerialResponseParser {
    private static let marker = Data("VIBESTICK_RESPONSE ".utf8)

    static func responsePayload(in data: Data) -> Data? {
        guard let markerRange = data.range(of: marker) else { return nil }
        let start = markerRange.upperBound
        let suffix = data[start...]
        guard let newline = suffix.firstIndex(of: 0x0A) else { return nil }
        let payload = Data(suffix[..<newline])
        guard !payload.isEmpty, payload.count <= 4096 else { return nil }
        return payload
    }
}

enum ManualBridgeAddressValidator {
    static func normalized(_ value: String?) throws -> String? {
        guard let value else { return nil }
        let candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return nil }
        guard candidate.count <= 253,
              !candidate.contains(":"),
              !candidate.contains("/"),
              !candidate.contains(" "),
              candidate.lowercased() != "localhost",
              candidate != "0.0.0.0" else {
            throw ManualBridgeAddressError.invalid
        }
        if isIPv4(candidate) { return candidate }

        let labels = candidate.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty, labels.allSatisfy({ label in
            guard !label.isEmpty, label.count <= 63,
                  label.first?.isLetter == true || label.first?.isNumber == true,
                  label.last?.isLetter == true || label.last?.isNumber == true else {
                return false
            }
            return label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        }) else {
            throw ManualBridgeAddressError.invalid
        }
        return candidate.lowercased()
    }

    static func isIPv4(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard !part.isEmpty, part.count <= 3, part.allSatisfy(\.isNumber),
                  let number = Int(part), (0...255).contains(number) else {
                return false
            }
            return String(number) == part || part == "0"
        }
    }
}

enum ManualBridgeAddressError: LocalizedError {
    case invalid

    var errorDescription: String? {
        "手动 Bridge 地址无效；请填写 IPv4 地址或局域网主机名"
    }
}
