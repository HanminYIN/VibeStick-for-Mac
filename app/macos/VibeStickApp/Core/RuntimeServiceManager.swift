import Darwin
import Foundation

struct CommandResult: Sendable {
    let status: Int32
    let standardOutput: String
    let standardError: String

    var succeeded: Bool { status == 0 }
}

private struct LaunchAgentInspection: Sendable {
    let loaded: Bool
    let running: Bool
    let programPath: String?
}

private enum BridgeEndpointState: Sendable {
    case expected
    case unexpected
    case unavailable
}

actor ProcessCommandRunner {
    func run(
        executable: String,
        arguments: [String],
        timeout: Duration = .seconds(6)
    ) async -> CommandResult {
        let process = Process()
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VibeStickCommand-\(UUID().uuidString)", isDirectory: true)
        let outputURL = temporaryDirectory.appendingPathComponent("stdout")
        let errorURL = temporaryDirectory.appendingPathComponent("stderr")
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        do {
            try FileManager.default.createDirectory(
                at: temporaryDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            FileManager.default.createFile(atPath: outputURL.path, contents: nil)
            FileManager.default.createFile(atPath: errorURL.path, contents: nil)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outputURL.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: errorURL.path)
        } catch {
            return CommandResult(status: 127, standardOutput: "", standardError: error.localizedDescription)
        }

        guard let outputHandle = try? FileHandle(forWritingTo: outputURL),
              let errorHandle = try? FileHandle(forWritingTo: errorURL) else {
            return CommandResult(status: 127, standardOutput: "", standardError: "无法创建命令输出文件")
        }
        defer {
            try? outputHandle.close()
            try? errorHandle.close()
        }
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = outputHandle
        process.standardError = errorHandle

        do {
            try process.run()
        } catch {
            return CommandResult(status: 127, standardOutput: "", standardError: error.localizedDescription)
        }

        let timeoutTask = Task {
            try? await Task.sleep(for: timeout)
            if process.isRunning {
                process.terminate()
                try? await Task.sleep(for: .milliseconds(750))
                if process.isRunning {
                    _ = Darwin.kill(process.processIdentifier, SIGKILL)
                }
            }
        }
        process.waitUntilExit()
        timeoutTask.cancel()

        try? outputHandle.synchronize()
        try? errorHandle.synchronize()
        let output = (try? Data(contentsOf: outputURL)) ?? Data()
        let error = (try? Data(contentsOf: errorURL)) ?? Data()
        return CommandResult(
            status: process.terminationStatus,
            standardOutput: String(decoding: output, as: UTF8.self),
            standardError: String(decoding: error, as: UTF8.self)
        )
    }
}

actor RuntimeServiceManager {
    private let fileManager: FileManager
    private let runner: ProcessCommandRunner
    private var cachedPastePermission: (value: Bool, checkedAt: Date)?

    init(
        fileManager: FileManager = .default,
        runner: ProcessCommandRunner = ProcessCommandRunner()
    ) {
        self.fileManager = fileManager
        self.runner = runner
    }

    func snapshot(
        bridge: BridgeSnapshot,
        forcePermissionCheck: Bool
    ) async -> RuntimeSnapshot {
        async let bridgeAgent = inspectLaunchAgent(label: "com.vibestick.bridge")
        async let hudAgent = inspectLaunchAgent(label: "com.vibestick.hud")
        async let pasteSignatureValid = validatePasteSignature()

        let bridgeInstalled = hasCompatibleLaunchAgent(
            plist: SupportPaths.bridgeLaunchAgent,
            executable: SupportPaths.bridgeExecutable,
            label: "com.vibestick.bridge"
        )
        let hudInstalled = hasCompatibleLaunchAgent(
            plist: SupportPaths.hudLaunchAgent,
            executable: SupportPaths.hudExecutable,
            label: "com.vibestick.hud"
        )
        let pasteInstalled = fileManager.isExecutableFile(atPath: SupportPaths.pasteExecutable.path)

        let inspectedBridgeAgent = await bridgeAgent
        let inspectedHUDAgent = await hudAgent
        let validPasteSignature = await pasteSignatureValid
        let recordingActive = recordingFileClaimsActive(
            bridgeProcessRunning: inspectedBridgeAgent.running
        )

        let bridgeHealth: ComponentHealth
        if bridge.hasPortConflict {
            bridgeHealth = ComponentHealth(
                kind: .bridge,
                phase: .portConflict,
                detail: "本机端口 8765 正由无法识别的程序响应",
                isInstalled: bridgeInstalled,
                ownership: .conflictingProcess
            )
        } else if bridge.isHealthy && !inspectedBridgeAgent.running {
            bridgeHealth = ComponentHealth(
                kind: .bridge,
                phase: .healthy,
                detail: "发现由其他方式运行的 Bridge " + (bridge.health?.bridgeVersion ?? ""),
                isInstalled: bridgeInstalled,
                ownership: .externalProcess
            )
        } else {
            bridgeHealth = ServiceStateResolver.launchAgent(
                kind: .bridge,
                installed: bridgeInstalled,
                loaded: inspectedBridgeAgent.loaded,
                running: inspectedBridgeAgent.running,
                ready: inspectedBridgeAgent.running ? bridge.isHealthy : nil,
                detail: bridge.isHealthy
                    ? "Bridge " + (bridge.health?.bridgeVersion ?? "") + " 已就绪"
                    : bridge.errorMessage
            )
        }
        let hudHealth = ServiceStateResolver.launchAgent(
            kind: .hud,
            installed: hudInstalled,
            loaded: inspectedHUDAgent.loaded,
            running: inspectedHUDAgent.running,
            ready: nil,
            detail: inspectedHUDAgent.running ? "屏幕提示服务正在运行" : nil
        )
        let pasteHealth = await inspectPaste(
            installed: pasteInstalled,
            signatureValid: validPasteSignature,
            force: forcePermissionCheck
        )

        return RuntimeSnapshot(
            bridge: bridgeHealth,
            hud: hudHealth,
            paste: pasteHealth,
            isRecordingActive: recordingActive,
            checkedAt: Date()
        )
    }

    // Migration discovery needs fresh ownership and active-work facts, but it
    // must not launch the Paste helper merely to probe Accessibility. This
    // read-only snapshot intentionally leaves Paste permission unknown; that
    // permission remains a separate post-migration/runtime-activation check.
    func migrationDiscoverySnapshot(bridge: BridgeSnapshot) async -> RuntimeSnapshot {
        async let bridgeAgent = inspectLaunchAgent(label: "com.vibestick.bridge")
        async let hudAgent = inspectLaunchAgent(label: "com.vibestick.hud")

        let bridgeInstalled = hasCompatibleLaunchAgent(
            plist: SupportPaths.bridgeLaunchAgent,
            executable: SupportPaths.bridgeExecutable,
            label: "com.vibestick.bridge"
        )
        let hudInstalled = hasCompatibleLaunchAgent(
            plist: SupportPaths.hudLaunchAgent,
            executable: SupportPaths.hudExecutable,
            label: "com.vibestick.hud"
        )
        let pasteInstalled = fileManager.isExecutableFile(atPath: SupportPaths.pasteExecutable.path)
        let inspectedBridgeAgent = await bridgeAgent
        let inspectedHUDAgent = await hudAgent

        let bridgeHealth: ComponentHealth
        if bridge.hasPortConflict {
            bridgeHealth = ComponentHealth(
                kind: .bridge,
                phase: .portConflict,
                detail: "迁移预检发现未知端口占用",
                isInstalled: bridgeInstalled,
                ownership: .conflictingProcess
            )
        } else if bridge.isHealthy && !inspectedBridgeAgent.running {
            bridgeHealth = ComponentHealth(
                kind: .bridge,
                phase: .healthy,
                detail: "迁移预检发现外部 Bridge",
                isInstalled: bridgeInstalled,
                ownership: .externalProcess
            )
        } else {
            bridgeHealth = ServiceStateResolver.launchAgent(
                kind: .bridge,
                installed: bridgeInstalled,
                loaded: inspectedBridgeAgent.loaded,
                running: inspectedBridgeAgent.running,
                ready: inspectedBridgeAgent.running ? bridge.isHealthy : nil,
                detail: nil
            )
        }
        let hudHealth = ServiceStateResolver.launchAgent(
            kind: .hud,
            installed: hudInstalled,
            loaded: inspectedHUDAgent.loaded,
            running: inspectedHUDAgent.running,
            ready: nil,
            detail: nil
        )
        let pasteHealth = ComponentHealth(
            kind: .paste,
            phase: pasteInstalled ? .unknown : .notInstalled,
            detail: pasteInstalled
                ? "迁移预检不启动 Paste 权限探针"
                : "未找到现有文字输入组件",
            isInstalled: pasteInstalled,
            ownership: pasteInstalled ? .legacyLaunchAgent : .none
        )

        return RuntimeSnapshot(
            bridge: bridgeHealth,
            hud: hudHealth,
            paste: pasteHealth,
            isRecordingActive: recordingFileClaimsActive(
                bridgeProcessRunning: inspectedBridgeAgent.running
            ),
            checkedAt: Date()
        )
    }

    func startServices() async -> ServiceActionResult {
        if let issue = await managedInstallationIssue() {
            return ServiceActionResult(success: false, message: issue)
        }
        let bridgeAgent = await inspectLaunchAgent(label: "com.vibestick.bridge")
        let endpointState = await bridgeEndpointState()
        if endpointState == .unexpected {
            return ServiceActionResult(success: false, message: "端口 8765 正由无法识别的程序占用。为避免冲突，控制中心没有启动第二个 Bridge。")
        }
        let bridgeIsExternal = !bridgeAgent.running && endpointState == .expected
        let bridge: CommandResult
        if bridgeIsExternal {
            bridge = CommandResult(status: 0, standardOutput: "externally managed", standardError: "")
        } else if bridgeAgent.running && endpointState == .unavailable {
            if await recordingSessionIsActive() {
                return ServiceActionResult(success: false, message: "当前录音状态仍处于活动中，控制中心不会强行重启异常 Bridge。")
            }
            bridge = await restart(label: "com.vibestick.bridge", plist: SupportPaths.bridgeLaunchAgent)
        } else {
            bridge = await start(label: "com.vibestick.bridge", plist: SupportPaths.bridgeLaunchAgent)
        }
        let hud = await start(label: "com.vibestick.hud", plist: SupportPaths.hudLaunchAgent)
        let result = combinedResult(bridge: bridge, hud: hud, verb: "启动")
        if bridgeIsExternal && result.success {
            return ServiceActionResult(
                success: true,
                message: "Bridge 已由其他方式运行；屏幕提示服务已启动。未创建第二个 Bridge。"
            )
        }
        return result
    }

    func restartServices() async -> ServiceActionResult {
        if let issue = await managedInstallationIssue() {
            return ServiceActionResult(success: false, message: issue)
        }
        if await recordingSessionIsActive() {
            return ServiceActionResult(success: false, message: "当前仍在录音或识别，请完成本次语音输入后再重新启动。")
        }
        if let reason = await unmanagedBridgeBlockReason() {
            return ServiceActionResult(success: false, message: reason)
        }
        let bridge = await restart(label: "com.vibestick.bridge", plist: SupportPaths.bridgeLaunchAgent)
        let hud = await restart(label: "com.vibestick.hud", plist: SupportPaths.hudLaunchAgent)
        return combinedResult(bridge: bridge, hud: hud, verb: "重启")
    }

    func stopServices() async -> ServiceActionResult {
        if let issue = await managedInstallationIssue() {
            return ServiceActionResult(success: false, message: issue)
        }
        if await recordingSessionIsActive() {
            return ServiceActionResult(success: false, message: "当前仍在录音或识别，请完成本次语音输入后再停止服务。")
        }
        if let reason = await unmanagedBridgeBlockReason() {
            return ServiceActionResult(success: false, message: reason)
        }
        let hud = await stop(label: "com.vibestick.hud", plist: SupportPaths.hudLaunchAgent)
        let bridge = await stop(label: "com.vibestick.bridge", plist: SupportPaths.bridgeLaunchAgent)
        return combinedResult(bridge: bridge, hud: hud, verb: "停止")
    }

    private func inspectLaunchAgent(label: String) async -> LaunchAgentInspection {
        let result = await runner.run(
            executable: "/bin/launchctl",
            arguments: ["print", "gui/\(getuid())/\(label)"]
        )
        return LaunchAgentInspection(
            loaded: result.succeeded,
            running: result.succeeded && LaunchAgentStateParser.isRunning(result.standardOutput),
            programPath: result.succeeded ? LaunchAgentStateParser.programPath(result.standardOutput) : nil
        )
    }

    private func managedInstallationIssue() async -> String? {
        let components = [
            (
                title: "设备连接服务",
                label: "com.vibestick.bridge",
                plist: SupportPaths.bridgeLaunchAgent,
                executable: SupportPaths.bridgeExecutable
            ),
            (
                title: "屏幕提示服务",
                label: "com.vibestick.hud",
                plist: SupportPaths.hudLaunchAgent,
                executable: SupportPaths.hudExecutable
            ),
        ]

        for component in components {
            guard hasCompatibleLaunchAgent(
                plist: component.plist,
                executable: component.executable,
                label: component.label
            ) else {
                return "\(component.title)的安装路径或后台配置不完整。控制中心不会启动未知程序，请先使用稳定版恢复流程。"
            }
            let inspection = await inspectLaunchAgent(label: component.label)
            if inspection.loaded && inspection.programPath != component.executable.path {
                return "\(component.title)当前载入的程序路径与稳定安装不一致。控制中心已保持只读，避免误操作。"
            }
        }
        return nil
    }

    private func unmanagedBridgeBlockReason() async -> String? {
        let inspection = await inspectLaunchAgent(label: "com.vibestick.bridge")
        let endpointState = await bridgeEndpointState()
        if endpointState == .unexpected {
            return "端口 8765 正由无法识别的程序占用，控制中心不会操作这个进程。"
        }
        if !inspection.running && endpointState == .expected {
            return "Bridge 正由其他方式运行，控制中心不会强行停止、重启或接管它。"
        }
        return nil
    }

    private func bridgeEndpointState() async -> BridgeEndpointState {
        guard let url = URL(string: "http://127.0.0.1:8765/health") else { return .unavailable }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .unavailable }
            guard http.statusCode == 200,
                  let health = try? JSONDecoder().decode(BridgeHealthDTO.self, from: data),
                  health.ok,
                  health.bridgeName == "vibestick-bridge" else {
                return .unexpected
            }
            return .expected
        } catch {
            return .unavailable
        }
    }

    private func hasCompatibleLaunchAgent(plist: URL, executable: URL, label: String) -> Bool {
        guard fileManager.isExecutableFile(atPath: executable.path),
              let data = try? Data(contentsOf: plist),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = object as? [String: Any],
              dictionary["Label"] as? String == label,
              let arguments = dictionary["ProgramArguments"] as? [String],
              arguments.first == executable.path else {
            return false
        }
        return true
    }

    private func recordingFileClaimsActive(bridgeProcessRunning: Bool) -> Bool {
        let data = try? Data(contentsOf: SupportPaths.recordingFile)
        let object = data.flatMap { try? JSONSerialization.jsonObject(with: $0) }
        let dictionary = object as? [String: Any]
        let attributes = try? fileManager.attributesOfItem(atPath: SupportPaths.recordingFile.path)
        return RecordingActivityResolver.shouldProtect(
            claimsActive: dictionary?["active"] as? Bool == true,
            modifiedAt: attributes?[.modificationDate] as? Date,
            bridgeProcessRunning: bridgeProcessRunning
        )
    }

    private func recordingSessionIsActive() async -> Bool {
        let inspection = await inspectLaunchAgent(label: "com.vibestick.bridge")
        return recordingFileClaimsActive(bridgeProcessRunning: inspection.running)
    }

    private func validatePasteSignature() async -> Bool {
        guard fileManager.fileExists(atPath: SupportPaths.pasteApp.path) else { return false }
        let result = await runner.run(
            executable: "/usr/bin/codesign",
            arguments: ["--verify", "--deep", "--strict", SupportPaths.pasteApp.path]
        )
        return result.succeeded
    }

    private func inspectPaste(
        installed: Bool,
        signatureValid: Bool,
        force: Bool
    ) async -> ComponentHealth {
        guard installed else {
            return ComponentHealth(
                kind: .paste,
                phase: .notInstalled,
                detail: "未找到现有文字输入组件",
                isInstalled: false
            )
        }
        guard signatureValid else {
            return ComponentHealth(
                kind: .paste,
                phase: .needsRepair,
                detail: "组件签名无法验证；M1 不会自动替换它",
                isInstalled: true
            )
        }

        if !force,
           let cached = cachedPastePermission,
           Date().timeIntervalSince(cached.checkedAt) < 60 {
            return pastePermissionHealth(cached.value)
        }

        guard let permission = await checkPastePermission() else {
            cachedPastePermission = nil
            return ComponentHealth(
                kind: .paste,
                phase: .needsRepair,
                detail: "无法读取文字输入权限状态",
                isInstalled: true
            )
        }
        cachedPastePermission = (permission, Date())
        return pastePermissionHealth(permission)
    }

    private func checkPastePermission() async -> Bool? {
        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("VibeStickPermission-\(UUID().uuidString)", isDirectory: true)
        let request = temporaryDirectory.appendingPathComponent("request.json")
        let response = temporaryDirectory.appendingPathComponent("response.json")
        defer { try? fileManager.removeItem(at: temporaryDirectory) }

        do {
            try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
            try Data("{\"operation\":\"check\"}".utf8).write(to: request, options: .atomic)
        } catch {
            return nil
        }

        let command = PastePermissionProbeProtocol.launchCommand(
            appPath: SupportPaths.pasteApp.path,
            requestPath: request.path,
            responsePath: response.path
        )
        _ = await runner.run(
            executable: command.executable,
            arguments: command.arguments
        )

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(4))
        var detectedPermission: Bool?
        repeat {
            if let data = try? Data(contentsOf: response),
               let permission = PastePermissionProbeProtocol.permission(from: data) {
                detectedPermission = permission
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        } while clock.now < deadline

        let unregister = PastePermissionProbeProtocol.unregisterCommand(
            appPath: SupportPaths.pasteApp.path
        )
        _ = await runner.run(
            executable: unregister.executable,
            arguments: unregister.arguments,
            timeout: .seconds(2)
        )
        return detectedPermission
    }

    private func pastePermissionHealth(_ enabled: Bool) -> ComponentHealth {
        ComponentHealth(
            kind: .paste,
            phase: enabled ? .healthy : .permissionMissing,
            detail: enabled ? "辅助功能权限已开启" : "请在系统设置中为 VibeStick Paste 开启辅助功能权限",
            isInstalled: true
        )
    }

    private func start(label: String, plist: URL) async -> CommandResult {
        let domain = "gui/\(getuid())"
        let inspection = await inspectLaunchAgent(label: label)
        if inspection.running {
            return CommandResult(status: 0, standardOutput: "already running", standardError: "")
        }
        if inspection.loaded {
            return await runner.run(
                executable: "/bin/launchctl",
                arguments: ["kickstart", "-k", "\(domain)/\(label)"]
            )
        }
        guard fileManager.fileExists(atPath: plist.path) else {
            return CommandResult(status: 66, standardOutput: "", standardError: "未找到 \(plist.lastPathComponent)")
        }
        return await runner.run(
            executable: "/bin/launchctl",
            arguments: ["bootstrap", domain, plist.path]
        )
    }

    private func restart(label: String, plist: URL) async -> CommandResult {
        let domain = "gui/\(getuid())"
        let inspection = await inspectLaunchAgent(label: label)
        if inspection.loaded {
            return await runner.run(
                executable: "/bin/launchctl",
                arguments: ["kickstart", "-k", "\(domain)/\(label)"]
            )
        }
        guard fileManager.fileExists(atPath: plist.path) else {
            return CommandResult(status: 66, standardOutput: "", standardError: "未找到 \(plist.lastPathComponent)")
        }
        return await runner.run(
            executable: "/bin/launchctl",
            arguments: ["bootstrap", domain, plist.path]
        )
    }

    private func stop(label: String, plist: URL) async -> CommandResult {
        let inspection = await inspectLaunchAgent(label: label)
        guard inspection.loaded else {
            return CommandResult(status: 0, standardOutput: "already stopped", standardError: "")
        }
        return await runner.run(
            executable: "/bin/launchctl",
            arguments: ["bootout", "gui/\(getuid())", plist.path]
        )
    }

    private func combinedResult(
        bridge: CommandResult,
        hud: CommandResult,
        verb: String
    ) -> ServiceActionResult {
        func acceptable(_ result: CommandResult) -> Bool {
            result.succeeded
        }

        let bridgeOK = acceptable(bridge)
        let hudOK = acceptable(hud)
        if bridgeOK && hudOK {
            return ServiceActionResult(success: true, message: "设备连接和屏幕提示服务已\(verb)。")
        }

        var failures: [String] = []
        if !bridgeOK { failures.append("设备连接服务：\(cleanError(bridge))") }
        if !hudOK { failures.append("屏幕提示服务：\(cleanError(hud))") }
        return ServiceActionResult(success: false, message: failures.joined(separator: "\n"))
    }

    private func cleanError(_ result: CommandResult) -> String {
        let message = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "系统返回状态 \(result.status)" : message
    }
}
