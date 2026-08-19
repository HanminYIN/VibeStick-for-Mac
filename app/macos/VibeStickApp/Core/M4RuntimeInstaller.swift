import CryptoKit
import Darwin
import Foundation

struct RuntimePayloadFile: Codable, Equatable, Sendable {
    let path: String
    let sha256: String
    let size: UInt64
    let mode: UInt16
}

struct RuntimePayloadManifest: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let payloadVersion: String
    let files: [RuntimePayloadFile]
}

enum RuntimeInstallFault: String, Equatable, Sendable {
    case none
    case afterStaging
    case afterBackup
    case afterSwitch
    case afterStart
}

struct RuntimeServiceCheckpoint: Codable, Equatable, Sendable {
    let bridgeWasLoaded: Bool
    let bridgeWasRunning: Bool
    let hudWasLoaded: Bool
    let hudWasRunning: Bool
}

struct RuntimeInstallPreflight: Equatable, Sendable {
    let checkpoint: RuntimeServiceCheckpoint
}

struct RuntimeInstallReceipt: Equatable, Sendable {
    let payloadVersion: String
    let backupDirectory: URL
    let preservedPasteIdentity: Bool
}

enum RuntimeInstallError: LocalizedError {
    case payloadUnavailable
    case invalidManifest(String)
    case unsafePayloadPath(String)
    case payloadMismatch(String)
    case blocked(String)
    case serviceFailure(String)
    case fileFailure(String)
    case injectedFault(RuntimeInstallFault)
    case transactionFailed(cause: String, rollback: String)

    var errorDescription: String? {
        switch self {
        case .payloadUnavailable:
            "安装包内没有找到经过签名的 M4-2 后台组件载荷。"
        case .invalidManifest(let detail):
            "后台组件清单无效：\(detail)"
        case .unsafePayloadPath(let path):
            "后台组件清单包含不安全路径：\(path)"
        case .payloadMismatch(let detail):
            "后台组件完整性校验失败：\(detail)"
        case .blocked(let detail):
            detail
        case .serviceFailure(let detail):
            "后台服务操作失败：\(detail)"
        case .fileFailure(let detail):
            "后台组件文件事务失败：\(detail)"
        case .injectedFault(let point):
            "测试故障已注入：\(point.rawValue)"
        case .transactionFailed(let cause, let rollback):
            "安装没有完成：\(cause)\n\n回退结果：\(rollback)"
        }
    }
}

enum RuntimePayloadDigest {
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

enum RuntimePayloadValidator {
    static let manifestName = "manifest-v1.json"
    static let requiredFiles: Set<String> = [
        "Components.noindex/VibeStick Bridge.app/Contents/MacOS/VibeStickBridge",
        "Components.noindex/VibeStick HUD.app/Contents/MacOS/VibeStickHUD",
        "Components.noindex/VibeStick Paste.app/Contents/MacOS/VibeStickPaste",
        "Components.noindex/VibeStick Paste.app/Contents/Resources/VibeStickPaste.build",
    ]

    static func validate(root: URL, fileManager: FileManager = .default) throws -> RuntimePayloadManifest {
        let manifestURL = root.appendingPathComponent(manifestName)
        guard fileManager.isReadableFile(atPath: manifestURL.path) else {
            throw RuntimeInstallError.payloadUnavailable
        }

        let manifest: RuntimePayloadManifest
        do {
            manifest = try JSONDecoder().decode(
                RuntimePayloadManifest.self,
                from: Data(contentsOf: manifestURL)
            )
        } catch {
            throw RuntimeInstallError.invalidManifest(error.localizedDescription)
        }
        guard manifest.schemaVersion == RuntimePayloadManifest.currentSchemaVersion else {
            throw RuntimeInstallError.invalidManifest("不支持 schema \(manifest.schemaVersion)")
        }
        guard !manifest.payloadVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RuntimeInstallError.invalidManifest("payloadVersion 为空")
        }

        var declaredPaths = Set<String>()
        for entry in manifest.files {
            try validate(relativePath: entry.path)
            guard declaredPaths.insert(entry.path).inserted else {
                throw RuntimeInstallError.invalidManifest("重复路径 \(entry.path)")
            }
            guard entry.sha256.count == 64,
                  entry.sha256.allSatisfy({ $0.isHexDigit }) else {
                throw RuntimeInstallError.invalidManifest("\(entry.path) 的 SHA-256 格式错误")
            }
            guard entry.mode & ~UInt16(0o777) == 0 else {
                throw RuntimeInstallError.invalidManifest("\(entry.path) 的权限位不安全")
            }
        }
        guard requiredFiles.isSubset(of: declaredPaths) else {
            let missing = requiredFiles.subtracting(declaredPaths).sorted().joined(separator: ", ")
            throw RuntimeInstallError.invalidManifest("缺少必需文件：\(missing)")
        }

        let actualPaths = try regularFilePaths(root: root, fileManager: fileManager)
        guard actualPaths == declaredPaths else {
            let missing = declaredPaths.subtracting(actualPaths).sorted()
            let extra = actualPaths.subtracting(declaredPaths).sorted()
            var details: [String] = []
            if !missing.isEmpty { details.append("缺少 \(missing.joined(separator: ", "))") }
            if !extra.isEmpty { details.append("多出 \(extra.joined(separator: ", "))") }
            throw RuntimeInstallError.payloadMismatch(details.joined(separator: "；"))
        }

        for entry in manifest.files {
            let fileURL = root.appendingPathComponent(entry.path)
            let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
            let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            guard size == entry.size else {
                throw RuntimeInstallError.payloadMismatch("\(entry.path) 大小不符")
            }
            let mode = (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
            guard mode == entry.mode else {
                throw RuntimeInstallError.payloadMismatch("\(entry.path) 权限位不符")
            }
            let digest = try RuntimePayloadDigest.sha256(of: fileURL)
            guard digest == entry.sha256.lowercased() else {
                throw RuntimeInstallError.payloadMismatch("\(entry.path) SHA-256 不符")
            }
        }
        return manifest
    }

    private static func validate(relativePath path: String) throws {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.hasPrefix("~"),
              !path.contains("\\") else {
            throw RuntimeInstallError.unsafePayloadPath(path)
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw RuntimeInstallError.unsafePayloadPath(path)
        }
    }

    private static func regularFilePaths(
        root: URL,
        fileManager: FileManager
    ) throws -> Set<String> {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: []
        ) else {
            throw RuntimeInstallError.payloadUnavailable
        }

        let rootPath = root.standardizedFileURL.path + "/"
        var paths = Set<String>()
        while let fileURL = enumerator.nextObject() as? URL {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            let relativePath = String(fileURL.standardizedFileURL.path.dropFirst(rootPath.count))
            if values.isSymbolicLink == true {
                throw RuntimeInstallError.unsafePayloadPath(relativePath)
            }
            guard values.isRegularFile == true, relativePath != manifestName else { continue }
            paths.insert(relativePath)
        }
        return paths
    }
}

struct RuntimeInstallLayout: Sendable {
    let supportDirectory: URL
    let launchAgentsDirectory: URL

    static let standard = RuntimeInstallLayout(
        supportDirectory: SupportPaths.supportDirectory,
        launchAgentsDirectory: SupportPaths.bridgeLaunchAgent.deletingLastPathComponent()
    )

    var runtimeDirectory: URL {
        supportDirectory.appendingPathComponent("runtime", isDirectory: true)
    }

    var componentsDirectory: URL {
        supportDirectory.appendingPathComponent("Components.noindex", isDirectory: true)
    }

    var bridgeApp: URL {
        componentsDirectory.appendingPathComponent("VibeStick Bridge.app", isDirectory: true)
    }

    var hudApp: URL {
        componentsDirectory.appendingPathComponent("VibeStick HUD.app", isDirectory: true)
    }

    var pasteApp: URL {
        componentsDirectory.appendingPathComponent("VibeStick Paste.app", isDirectory: true)
    }

    var bridgeLaunchAgent: URL {
        launchAgentsDirectory.appendingPathComponent("com.vibestick.bridge.plist")
    }

    var hudLaunchAgent: URL {
        launchAgentsDirectory.appendingPathComponent("com.vibestick.hud.plist")
    }

    var backupsDirectory: URL {
        supportDirectory.appendingPathComponent("Backups.noindex", isDirectory: true)
    }

    var stagingDirectory: URL {
        supportDirectory.appendingPathComponent(".M4Installing.noindex", isDirectory: true)
    }
}

protocol RuntimeInstallServiceControlling: Sendable {
    func preflight() async throws -> RuntimeInstallPreflight
    func revalidateBeforeMutation() async throws -> RuntimeServiceCheckpoint
    func validateComponents(at componentsDirectory: URL) async throws
    func canPreservePasteIdentity(existing: URL, candidate: URL) async -> Bool
    func stopManagedServices() async throws
    func startInstalledServices() async throws
    func verifyInstalledServices() async throws
    func restoreServiceState(_ checkpoint: RuntimeServiceCheckpoint) async throws
}

struct RuntimeFreshInstallConfigurationBootstrapReceipt: Equatable, Sendable {
    let createdManagedConfiguration: Bool
    let createdBridgeCredential: Bool

    static let unchanged = RuntimeFreshInstallConfigurationBootstrapReceipt(
        createdManagedConfiguration: false,
        createdBridgeCredential: false
    )
}

protocol RuntimeConfigurationBootstrapping: Sendable {
    func prepareIfNeeded() async throws -> RuntimeFreshInstallConfigurationBootstrapReceipt
    func rollback(_ receipt: RuntimeFreshInstallConfigurationBootstrapReceipt) async throws
}

actor RuntimeFreshInstallConfigurationBootstrapper: RuntimeConfigurationBootstrapping {
    private let supportDirectory: URL
    private let fileManager: FileManager
    private let credentialVault: any M4OfflineCredentialVault
    private let tokenGenerator: @Sendable () throws -> Data

    init(
        supportDirectory: URL,
        credentialVault: any M4OfflineCredentialVault = M4VersionedKeychainCredentialVault.live(),
        tokenGenerator: @escaping @Sendable () throws -> Data = {
            var generator = SystemRandomNumberGenerator()
            let randomBytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
            return Data(randomBytes).base64EncodedData()
        }
    ) {
        self.supportDirectory = supportDirectory
        self.fileManager = .default
        self.credentialVault = credentialVault
        self.tokenGenerator = tokenGenerator
    }

    func prepareIfNeeded() async throws -> RuntimeFreshInstallConfigurationBootstrapReceipt {
        let configurationURL = supportDirectory.appendingPathComponent("managed-runtime-v1.json")
        let legacyEnvironmentURL = supportDirectory.appendingPathComponent(".env")
        guard !fileManager.fileExists(atPath: configurationURL.path),
              !fileManager.fileExists(atPath: legacyEnvironmentURL.path) else {
            return .unchanged
        }

        let bridgeReference = M4VersionedCredentialReference.managed(.bridgeToken)
        let temporaryConfigurationURL = supportDirectory.appendingPathComponent(
            ".managed-runtime-v1.\(UUID().uuidString).tmp"
        )
        var createdBridgeCredential = false
        var createdManagedConfiguration = false
        defer { try? fileManager.removeItem(at: temporaryConfigurationURL) }
        do {
            try fileManager.createDirectory(
                at: supportDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: supportDirectory.path
            )

            if try await credentialVault.contains(bridgeReference) == false {
                let token = try tokenGenerator()
                guard token.count >= 32 else {
                    throw RuntimeInstallError.blocked("无法生成满足长度要求的 Bridge 安全凭据。")
                }
                try await credentialVault.stage(token, for: bridgeReference)
                createdBridgeCredential = true
            }

            let configuration = try M4ManagedRuntimeConfiguration(
                schemaVersion: M4ManagedRuntimeConfiguration.currentSchemaVersion,
                credentialReferences: [bridgeReference],
                asr: nil,
                agentProvider: "auto",
                projectPresentation: nil,
                voiceDelivery: M4ManagedVoiceDelivery(sendMode: "paste_only"),
                soundEnabled: nil
            ).validated()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(configuration)
            try data.write(to: temporaryConfigurationURL, options: .atomic)
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: temporaryConfigurationURL.path
            )
            try fileManager.moveItem(at: temporaryConfigurationURL, to: configurationURL)
            createdManagedConfiguration = true
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: configurationURL.path
            )
            return RuntimeFreshInstallConfigurationBootstrapReceipt(
                createdManagedConfiguration: true,
                createdBridgeCredential: createdBridgeCredential
            )
        } catch {
            if createdManagedConfiguration {
                try? fileManager.removeItem(at: configurationURL)
            }
            if createdBridgeCredential {
                try? await credentialVault.discard(bridgeReference)
            }
            if let error = error as? RuntimeInstallError { throw error }
            throw RuntimeInstallError.fileFailure("无法准备全新安装的 Bridge 安全配置。")
        }
    }

    func rollback(_ receipt: RuntimeFreshInstallConfigurationBootstrapReceipt) async throws {
        let configurationURL = supportDirectory.appendingPathComponent("managed-runtime-v1.json")
        let bridgeReference = M4VersionedCredentialReference.managed(.bridgeToken)
        if receipt.createdManagedConfiguration,
           fileManager.fileExists(atPath: configurationURL.path) {
            try fileManager.removeItem(at: configurationURL)
        }
        if receipt.createdBridgeCredential {
            try await credentialVault.discard(bridgeReference)
        }
    }
}

actor RuntimeLaunchAgentInstallController: RuntimeInstallServiceControlling {
    static let serviceVerificationAttempts = 480
    static let serviceVerificationIntervalMilliseconds = 250

    private struct AgentState: Sendable {
        let loaded: Bool
        let running: Bool
        let programPath: String?
    }

    private enum EndpointState: Equatable, Sendable {
        case expected
        case unexpected
        case unavailable
    }

    private let layout: RuntimeInstallLayout
    private let fileManager: FileManager
    private let runner: ProcessCommandRunner

    init(
        layout: RuntimeInstallLayout = .standard,
        fileManager: FileManager = .default,
        runner: ProcessCommandRunner = ProcessCommandRunner()
    ) {
        self.layout = layout
        self.fileManager = fileManager
        self.runner = runner
    }

    func preflight() async throws -> RuntimeInstallPreflight {
        let checkpoint = try await mutationSafetyCheck()
        return RuntimeInstallPreflight(checkpoint: checkpoint)
    }

    func revalidateBeforeMutation() async throws -> RuntimeServiceCheckpoint {
        try await mutationSafetyCheck()
    }

    private func mutationSafetyCheck() async throws -> RuntimeServiceCheckpoint {
        async let bridgeInspection = inspect(label: "com.vibestick.bridge")
        async let hudInspection = inspect(label: "com.vibestick.hud")
        async let endpointInspection = bridgeEndpointState()

        let bridge = await bridgeInspection
        let hud = await hudInspection
        let endpoint = await endpointInspection

        if bridge.loaded,
           let programPath = bridge.programPath,
           programPath != layout.bridgeApp.appendingPathComponent("Contents/MacOS/VibeStickBridge").path {
            throw RuntimeInstallError.blocked("当前载入的 Bridge 不属于 VibeStick 受管路径；安装器不会接管或替换它。")
        }
        if hud.loaded,
           let programPath = hud.programPath,
           programPath != layout.hudApp.appendingPathComponent("Contents/MacOS/VibeStickHUD").path {
            throw RuntimeInstallError.blocked("当前载入的 HUD 不属于 VibeStick 受管路径；安装器不会接管或替换它。")
        }
        if endpoint == .unexpected {
            throw RuntimeInstallError.blocked("端口 8765 正由无法识别的程序响应；安装器不会停止或替换该进程。")
        }
        if endpoint == .expected && !bridge.running {
            throw RuntimeInstallError.blocked("检测到由其他方式运行的 Bridge；安装器不会接管它。")
        }
        if recordingFileClaimsActive(bridgeProcessRunning: bridge.running) {
            throw RuntimeInstallError.blocked("当前仍在录音或识别；请完成本次语音输入后再安装或修复后台组件。")
        }

        return RuntimeServiceCheckpoint(
            bridgeWasLoaded: bridge.loaded,
            bridgeWasRunning: bridge.running,
            hudWasLoaded: hud.loaded,
            hudWasRunning: hud.running
        )
    }

    func validateComponents(at componentsDirectory: URL) async throws {
        for appName in ["VibeStick Bridge.app", "VibeStick HUD.app", "VibeStick Paste.app"] {
            let app = componentsDirectory.appendingPathComponent(appName, isDirectory: true)
            let result = await runner.run(
                executable: "/usr/bin/codesign",
                arguments: ["--verify", "--deep", "--strict", app.path]
            )
            guard result.succeeded else {
                throw RuntimeInstallError.payloadMismatch("\(appName) 的代码签名无法验证")
            }
        }
    }

    func canPreservePasteIdentity(existing: URL, candidate: URL) async -> Bool {
        let relativeStamp = "Contents/Resources/VibeStickPaste.build"
        guard fileManager.isExecutableFile(
            atPath: existing.appendingPathComponent("Contents/MacOS/VibeStickPaste").path
        ),
        let existingStamp = try? String(
            contentsOf: existing.appendingPathComponent(relativeStamp),
            encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines),
        let candidateStamp = try? String(
            contentsOf: candidate.appendingPathComponent(relativeStamp),
            encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines),
        !existingStamp.isEmpty,
        existingStamp == candidateStamp else {
            return false
        }
        let result = await runner.run(
            executable: "/usr/bin/codesign",
            arguments: ["--verify", "--deep", "--strict", existing.path]
        )
        return result.succeeded
    }

    func stopManagedServices() async throws {
        try await stopIfLoaded(label: "com.vibestick.hud")
        try await stopIfLoaded(label: "com.vibestick.bridge")

        for _ in 0..<50 {
            async let bridgeInspection = inspect(label: "com.vibestick.bridge")
            async let hudInspection = inspect(label: "com.vibestick.hud")
            async let endpointInspection = bridgeEndpointState()
            let bridge = await bridgeInspection
            let hud = await hudInspection
            let endpoint = await endpointInspection
            if !bridge.loaded && !hud.loaded && endpoint == .unavailable { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        throw RuntimeInstallError.serviceFailure(
            "旧 Bridge、HUD 或端口 8765 没有在等待时间内完全退出；未继续切换文件"
        )
    }

    func startInstalledServices() async throws {
        try await bootstrap(label: "com.vibestick.bridge", plist: layout.bridgeLaunchAgent)
        do {
            try await bootstrap(label: "com.vibestick.hud", plist: layout.hudLaunchAgent)
        } catch {
            try? await stopIfLoaded(label: "com.vibestick.bridge")
            throw error
        }
    }

    func verifyInstalledServices() async throws {
        try await validateComponents(at: layout.componentsDirectory)
        var lastBridge = await inspect(label: "com.vibestick.bridge")
        var lastHUD = await inspect(label: "com.vibestick.hud")
        var lastEndpoint = await bridgeEndpointState()
        for _ in 0..<Self.serviceVerificationAttempts {
            async let bridgeInspection = inspect(label: "com.vibestick.bridge")
            async let hudInspection = inspect(label: "com.vibestick.hud")
            async let endpointInspection = bridgeEndpointState()
            lastBridge = await bridgeInspection
            lastHUD = await hudInspection
            lastEndpoint = await endpointInspection
            if lastBridge.running && lastHUD.running && lastEndpoint == .expected { return }
            try? await Task.sleep(
                for: .milliseconds(Self.serviceVerificationIntervalMilliseconds)
            )
        }
        throw RuntimeInstallError.serviceFailure(
            "新组件没有在等待时间内同时达到健康状态（Bridge：\(agentDescription(lastBridge))；HUD：\(agentDescription(lastHUD))；端口：\(endpointDescription(lastEndpoint))）"
        )
    }

    func restoreServiceState(_ checkpoint: RuntimeServiceCheckpoint) async throws {
        try await stopIfLoaded(label: "com.vibestick.hud")
        try await stopIfLoaded(label: "com.vibestick.bridge")
        if checkpoint.bridgeWasRunning {
            try await bootstrap(label: "com.vibestick.bridge", plist: layout.bridgeLaunchAgent)
        }
        if checkpoint.hudWasRunning {
            try await bootstrap(label: "com.vibestick.hud", plist: layout.hudLaunchAgent)
        }
    }

    private func inspect(label: String) async -> AgentState {
        let result = await runner.run(
            executable: "/bin/launchctl",
            arguments: ["print", "gui/\(getuid())/\(label)"]
        )
        return AgentState(
            loaded: result.succeeded,
            running: result.succeeded && LaunchAgentStateParser.isRunning(result.standardOutput),
            programPath: result.succeeded ? LaunchAgentStateParser.programPath(result.standardOutput) : nil
        )
    }

    private func stopIfLoaded(label: String) async throws {
        guard await inspect(label: label).loaded else { return }
        let result = await runner.run(
            executable: "/bin/launchctl",
            arguments: ["bootout", "gui/\(getuid())/\(label)"]
        )
        guard result.succeeded else {
            throw RuntimeInstallError.serviceFailure(cleanError(result))
        }
    }

    private func bootstrap(label: String, plist: URL) async throws {
        guard fileManager.isReadableFile(atPath: plist.path) else {
            throw RuntimeInstallError.serviceFailure("未找到 \(plist.lastPathComponent)")
        }
        if await inspect(label: label).loaded { return }
        let result = await runner.run(
            executable: "/bin/launchctl",
            arguments: ["bootstrap", "gui/\(getuid())", plist.path]
        )
        guard result.succeeded else {
            throw RuntimeInstallError.serviceFailure(cleanError(result))
        }
    }

    private func bridgeEndpointState() async -> EndpointState {
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

    private func recordingFileClaimsActive(bridgeProcessRunning: Bool) -> Bool {
        let recordingFile = layout.supportDirectory.appendingPathComponent("recording.json")
        let data = try? Data(contentsOf: recordingFile)
        let object = data.flatMap { try? JSONSerialization.jsonObject(with: $0) }
        let dictionary = object as? [String: Any]
        let attributes = try? fileManager.attributesOfItem(atPath: recordingFile.path)
        return RecordingActivityResolver.shouldProtect(
            claimsActive: dictionary?["active"] as? Bool == true,
            modifiedAt: attributes?[.modificationDate] as? Date,
            bridgeProcessRunning: bridgeProcessRunning
        )
    }

    private func cleanError(_ result: CommandResult) -> String {
        let error = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        return error.isEmpty ? "系统返回状态 \(result.status)" : error
    }

    private func agentDescription(_ state: AgentState) -> String {
        "loaded=\(state.loaded), running=\(state.running)"
    }

    private func endpointDescription(_ state: EndpointState) -> String {
        switch state {
        case .expected: "VibeStick"
        case .unexpected: "未知服务"
        case .unavailable: "未就绪"
        }
    }
}

actor RuntimeInstaller {
    private struct ManagedTarget {
        let key: String
        let staged: URL?
        let installed: URL
        let backup: URL
    }

    private struct BackupState: Codable {
        let schemaVersion: Int
        let payloadVersion: String
        let createdAt: Date
        let originalPaths: [String]
        let preservedPasteIdentity: Bool
    }

    private struct TransactionReceipt: Codable {
        let schemaVersion: Int
        let payloadVersion: String
        let completedAt: Date
        let outcome: String
        let preservedPasteIdentity: Bool
    }

    private let layout: RuntimeInstallLayout
    private let payloadRoot: URL?
    private let fileManager: FileManager
    private let serviceController: any RuntimeInstallServiceControlling
    private let configurationBootstrapper: any RuntimeConfigurationBootstrapping

    init(
        layout: RuntimeInstallLayout = .standard,
        payloadRoot: URL? = Bundle.main.resourceURL?
            .appendingPathComponent("RuntimePayload.noindex", isDirectory: true),
        fileManager: FileManager = .default,
        serviceController: (any RuntimeInstallServiceControlling)? = nil,
        configurationBootstrapper: (any RuntimeConfigurationBootstrapping)? = nil
    ) {
        self.layout = layout
        self.payloadRoot = payloadRoot
        self.fileManager = fileManager
        self.serviceController = serviceController ?? RuntimeLaunchAgentInstallController(
            layout: layout
        )
        self.configurationBootstrapper = configurationBootstrapper
            ?? RuntimeFreshInstallConfigurationBootstrapper(
                supportDirectory: layout.supportDirectory
            )
    }

    func install(fault: RuntimeInstallFault = .none) async throws -> RuntimeInstallReceipt {
        guard let payloadRoot else { throw RuntimeInstallError.payloadUnavailable }
        let manifest = try RuntimePayloadValidator.validate(root: payloadRoot, fileManager: fileManager)
        let preflight = try await serviceController.preflight()

        let transactionID = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-") + "-" + UUID().uuidString
        let stagingRoot = layout.stagingDirectory.appendingPathComponent(transactionID, isDirectory: true)
        let stagedInstallRoot = stagingRoot.appendingPathComponent("install", isDirectory: true)
        let backupRoot = layout.backupsDirectory.appendingPathComponent(transactionID, isDirectory: true)
        let backupManagedRoot = backupRoot.appendingPathComponent("managed", isDirectory: true)
        var originalPaths = Set<String>()
        var servicesWereStopped = false
        var filesystemWasTouched = false
        var preservedPasteIdentity = false
        var rollbackCheckpoint = preflight.checkpoint
        var configurationBootstrapReceipt: RuntimeFreshInstallConfigurationBootstrapReceipt?

        do {
            try preparePrivateDirectories(stagingRoot: stagingRoot, backupRoot: backupRoot)
            try stagePayload(
                from: payloadRoot,
                manifest: manifest,
                to: stagedInstallRoot
            )
            _ = try RuntimePayloadValidator.validate(root: stagedInstallRoot, fileManager: fileManager)
            try writeLaunchAgents(to: stagedInstallRoot)
            try await serviceController.validateComponents(
                at: stagedInstallRoot.appendingPathComponent("Components.noindex", isDirectory: true)
            )
            if fault == .afterStaging { throw RuntimeInstallError.injectedFault(fault) }

            let stagedPaste = stagedInstallRoot
                .appendingPathComponent("Components.noindex/VibeStick Paste.app", isDirectory: true)
            preservedPasteIdentity = await serviceController.canPreservePasteIdentity(
                existing: layout.pasteApp,
                candidate: stagedPaste
            )

            var targets = managedTargets(
                stagedInstallRoot: stagedInstallRoot,
                backupManagedRoot: backupManagedRoot
            )
            if preservedPasteIdentity {
                let pasteTarget = targets.remove(at: 3)
                if fileManager.fileExists(atPath: pasteTarget.installed.path) {
                    try createParentDirectory(for: pasteTarget.backup)
                    try fileManager.copyItem(at: pasteTarget.installed, to: pasteTarget.backup)
                    originalPaths.insert(pasteTarget.key)
                }
            }

            for target in targets where fileManager.fileExists(atPath: target.installed.path) {
                originalPaths.insert(target.key)
            }
            try writeBackupState(
                BackupState(
                    schemaVersion: 1,
                    payloadVersion: manifest.payloadVersion,
                    createdAt: Date(),
                    originalPaths: originalPaths.sorted(),
                    preservedPasteIdentity: preservedPasteIdentity
                ),
                to: backupRoot
            )

            rollbackCheckpoint = try await serviceController.revalidateBeforeMutation()
            try await serviceController.stopManagedServices()
            servicesWereStopped = true

            for target in targets {
                try createParentDirectory(for: target.installed)
                try createParentDirectory(for: target.backup)
                if fileManager.fileExists(atPath: target.installed.path) {
                    try fileManager.moveItem(at: target.installed, to: target.backup)
                    filesystemWasTouched = true
                }
            }
            if fault == .afterBackup { throw RuntimeInstallError.injectedFault(fault) }

            for target in targets {
                guard let staged = target.staged else { continue }
                try fileManager.moveItem(at: staged, to: target.installed)
                filesystemWasTouched = true
            }
            if fault == .afterSwitch { throw RuntimeInstallError.injectedFault(fault) }

            configurationBootstrapReceipt = try await configurationBootstrapper.prepareIfNeeded()
            try await serviceController.startInstalledServices()
            if fault == .afterStart { throw RuntimeInstallError.injectedFault(fault) }
            try await serviceController.verifyInstalledServices()

            try writeReceipt(
                TransactionReceipt(
                    schemaVersion: 1,
                    payloadVersion: manifest.payloadVersion,
                    completedAt: Date(),
                    outcome: "installed",
                    preservedPasteIdentity: preservedPasteIdentity
                ),
                to: backupRoot
            )
            try? fileManager.removeItem(at: stagingRoot)
            return RuntimeInstallReceipt(
                payloadVersion: manifest.payloadVersion,
                backupDirectory: backupRoot,
                preservedPasteIdentity: preservedPasteIdentity
            )
        } catch {
            let cause = error.localizedDescription
            var rollbackOutcome = "无需回退，现有运行时未改变。"
            var configurationRollbackFailed = false
            if let configurationBootstrapReceipt {
                do {
                    try await configurationBootstrapper.rollback(configurationBootstrapReceipt)
                } catch {
                    configurationRollbackFailed = true
                }
            }
            if servicesWereStopped || filesystemWasTouched {
                do {
                    try await rollback(
                        stagedInstallRoot: stagedInstallRoot,
                        backupManagedRoot: backupManagedRoot,
                        originalPaths: originalPaths,
                        preservedPasteIdentity: preservedPasteIdentity,
                        checkpoint: rollbackCheckpoint
                    )
                    rollbackOutcome = "旧运行时和原服务状态已恢复。"
                } catch {
                    rollbackOutcome = "自动回退未完整通过：\(error.localizedDescription)"
                }
            }
            if configurationRollbackFailed {
                rollbackOutcome += " 新建的 Bridge 安全配置未能完整撤销。"
            }
            try? writeReceipt(
                TransactionReceipt(
                    schemaVersion: 1,
                    payloadVersion: manifest.payloadVersion,
                    completedAt: Date(),
                    outcome: "rolled-back",
                    preservedPasteIdentity: preservedPasteIdentity
                ),
                to: backupRoot
            )
            try? fileManager.removeItem(at: stagingRoot)
            throw RuntimeInstallError.transactionFailed(cause: cause, rollback: rollbackOutcome)
        }
    }

    private func preparePrivateDirectories(stagingRoot: URL, backupRoot: URL) throws {
        do {
            for directory in [layout.supportDirectory, layout.stagingDirectory, stagingRoot, backupRoot] {
                try fileManager.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            }
            try fileManager.createDirectory(
                at: layout.launchAgentsDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            throw RuntimeInstallError.fileFailure(error.localizedDescription)
        }
    }

    private func stagePayload(
        from payloadRoot: URL,
        manifest: RuntimePayloadManifest,
        to stagedInstallRoot: URL
    ) throws {
        do {
            try fileManager.createDirectory(at: stagedInstallRoot, withIntermediateDirectories: true)
            for entry in manifest.files {
                let source = payloadRoot.appendingPathComponent(entry.path)
                let destination = stagedInstallRoot.appendingPathComponent(entry.path)
                try createParentDirectory(for: destination)
                try fileManager.copyItem(at: source, to: destination)
                try fileManager.setAttributes(
                    [.posixPermissions: NSNumber(value: entry.mode)],
                    ofItemAtPath: destination.path
                )
            }
            try fileManager.copyItem(
                at: payloadRoot.appendingPathComponent(RuntimePayloadValidator.manifestName),
                to: stagedInstallRoot.appendingPathComponent(RuntimePayloadValidator.manifestName)
            )
        } catch let error as RuntimeInstallError {
            throw error
        } catch {
            throw RuntimeInstallError.fileFailure(error.localizedDescription)
        }
    }

    private func writeLaunchAgents(to stagedInstallRoot: URL) throws {
        let launchAgents = stagedInstallRoot.appendingPathComponent("LaunchAgents", isDirectory: true)
        try fileManager.createDirectory(at: launchAgents, withIntermediateDirectories: true)

        let bridgeExecutable = layout.bridgeApp.appendingPathComponent("Contents/MacOS/VibeStickBridge").path
        let hudExecutable = layout.hudApp.appendingPathComponent("Contents/MacOS/VibeStickHUD").path
        let bridge: [String: Any] = [
            "Label": "com.vibestick.bridge",
            "AssociatedBundleIdentifiers": ["io.github.hanminyin.vibestick"],
            "ProgramArguments": [bridgeExecutable],
            "WorkingDirectory": layout.supportDirectory.path,
            "EnvironmentVariables": [
                "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            ],
            "RunAtLoad": true,
            "KeepAlive": true,
            "StandardOutPath": layout.supportDirectory.appendingPathComponent("bridge.log").path,
            "StandardErrorPath": layout.supportDirectory.appendingPathComponent("bridge.err.log").path,
        ]
        let hud: [String: Any] = [
            "Label": "com.vibestick.hud",
            "AssociatedBundleIdentifiers": ["io.github.hanminyin.vibestick"],
            "ProgramArguments": [hudExecutable],
            "RunAtLoad": true,
            "KeepAlive": true,
            "StandardOutPath": layout.supportDirectory.appendingPathComponent("hud.log").path,
            "StandardErrorPath": layout.supportDirectory.appendingPathComponent("hud.err.log").path,
        ]
        try writePropertyList(
            bridge,
            to: launchAgents.appendingPathComponent("com.vibestick.bridge.plist")
        )
        try writePropertyList(
            hud,
            to: launchAgents.appendingPathComponent("com.vibestick.hud.plist")
        )
    }

    private func writePropertyList(_ value: [String: Any], to url: URL) throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: value,
            format: .xml,
            options: 0
        )
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func managedTargets(
        stagedInstallRoot: URL,
        backupManagedRoot: URL
    ) -> [ManagedTarget] {
        func target(key: String, staged: URL?, installed: URL) -> ManagedTarget {
            ManagedTarget(
                key: key,
                staged: staged,
                installed: installed,
                backup: backupManagedRoot.appendingPathComponent(key)
            )
        }
        return [
            target(
                key: "support/runtime",
                staged: nil,
                installed: layout.runtimeDirectory
            ),
            target(
                key: "support/Components.noindex/VibeStick Bridge.app",
                staged: stagedInstallRoot.appendingPathComponent("Components.noindex/VibeStick Bridge.app", isDirectory: true),
                installed: layout.bridgeApp
            ),
            target(
                key: "support/Components.noindex/VibeStick HUD.app",
                staged: stagedInstallRoot.appendingPathComponent("Components.noindex/VibeStick HUD.app", isDirectory: true),
                installed: layout.hudApp
            ),
            target(
                key: "support/Components.noindex/VibeStick Paste.app",
                staged: stagedInstallRoot.appendingPathComponent("Components.noindex/VibeStick Paste.app", isDirectory: true),
                installed: layout.pasteApp
            ),
            target(
                key: "launch-agents/com.vibestick.bridge.plist",
                staged: stagedInstallRoot.appendingPathComponent("LaunchAgents/com.vibestick.bridge.plist"),
                installed: layout.bridgeLaunchAgent
            ),
            target(
                key: "launch-agents/com.vibestick.hud.plist",
                staged: stagedInstallRoot.appendingPathComponent("LaunchAgents/com.vibestick.hud.plist"),
                installed: layout.hudLaunchAgent
            ),
        ]
    }

    private func rollback(
        stagedInstallRoot: URL,
        backupManagedRoot: URL,
        originalPaths: Set<String>,
        preservedPasteIdentity: Bool,
        checkpoint: RuntimeServiceCheckpoint
    ) async throws {
        try? await serviceController.stopManagedServices()
        var targets = managedTargets(
            stagedInstallRoot: stagedInstallRoot,
            backupManagedRoot: backupManagedRoot
        )
        if preservedPasteIdentity { targets.remove(at: 3) }

        let quarantine = stagedInstallRoot.appendingPathComponent("failed-install", isDirectory: true)
        for target in targets.reversed() {
            if fileManager.fileExists(atPath: target.installed.path) {
                let displaced = quarantine.appendingPathComponent(target.key)
                try createParentDirectory(for: displaced)
                try fileManager.moveItem(at: target.installed, to: displaced)
            }
            if originalPaths.contains(target.key),
               fileManager.fileExists(atPath: target.backup.path) {
                try createParentDirectory(for: target.installed)
                try fileManager.moveItem(at: target.backup, to: target.installed)
            }
        }
        try await serviceController.restoreServiceState(checkpoint)
    }

    private func writeBackupState(_ state: BackupState, to backupRoot: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let url = backupRoot.appendingPathComponent("backup-state-v1.json")
        try encoder.encode(state).write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func writeReceipt(_ receipt: TransactionReceipt, to backupRoot: URL) throws {
        try fileManager.createDirectory(at: backupRoot, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let url = backupRoot.appendingPathComponent("install-receipt-v1.json")
        try encoder.encode(receipt).write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func createParentDirectory(for url: URL) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }
}
