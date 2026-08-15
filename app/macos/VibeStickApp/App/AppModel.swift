import Combine
import Foundation
import SwiftUI

private final class StartupSmokeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    func currentValue() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var bridgeSnapshot = BridgeSnapshot.empty
    @Published private(set) var runtimeSnapshot = RuntimeSnapshot.waiting
    @Published private(set) var flashingToolSnapshot = FlashingToolSnapshot.checking()
    @Published private(set) var deviceBackupSnapshot = DeviceBackupSnapshot.idle
    @Published private(set) var configurationSummary = LegacyConfigurationSummary.empty
    @Published private(set) var keychainSummary = KeychainSummary.empty
    @Published private(set) var voiceInteractionSummary = VoiceInteractionSummary.empty
    @Published private(set) var configuration = AppConfiguration.standard
    @Published private(set) var asrDraft = ASRConfiguration.standard
    @Published private(set) var asrTestFeedback = ASRTestFeedback.idle
    @Published private(set) var deviceConfiguration = DeviceConfiguration.standard
    @Published private(set) var bridgeDevices: BridgeDevicesDTO?
    @Published private(set) var pairingPhase: PairingPhase = .idle
    @Published private(set) var isRefreshing = false
    @Published private(set) var serviceActionInProgress = false
    @Published private(set) var runtimeInstallInProgress = false
    @Published private(set) var flashingToolActionInProgress = false
    @Published private(set) var deviceBackupActionInProgress = false
    @Published private(set) var deviceConfigurationSaveInProgress = false
    @Published private(set) var asrSettingsSaveInProgress = false
    @Published var presentedMessage: AppMessage?
    @Published var runtimeInstallConfirmationPresented = false
    @Published var flashingToolDownloadConfirmationPresented = false
    @Published var flashingToolPreparationConfirmationPresented = false
    @Published var flashingToolRemovalConfirmationPresented = false
    @Published var deviceInspectionConfirmationPresented = false
    @Published var deviceBackupConfirmationPresented = false

    private let bridgeClient: BridgeClient
    private let runtimeManager: RuntimeServiceManager
    private let runtimeInstaller: RuntimeInstaller
    private let flashingToolManager: FlashingToolManager
    private let deviceBackupManager: DeviceBackupManager
    private let configurationInspector: ConfigurationInspector
    private let preferencesStore: PreferencesStore
    private let loginItemController: LoginItemController
    private let deviceConfigurationStore: DeviceConfigurationStore
    private let usbDeviceDetector: USBDeviceDetector
    private let devicePairingManager: DevicePairingManager
    private let asrSecretManager: any ASRSecretManaging
    private let asrTestService: any ASRTesting
    private let asrTestAudioProvider: any ASRTestAudioProviding
    private var refreshLoop: Task<Void, Never>?
    private var startupSmokeProbe: Task<Void, Never>?
    private var startupSmokeObservation: AnyCancellable?
    private let startupSmokeCounter = StartupSmokeCounter()
    private var startupSmokeWindowVisible = false
    private var hasStarted = false
    private var hasEditedASRDraft = false

    init(
        bridgeClient: BridgeClient = BridgeClient(),
        runtimeManager: RuntimeServiceManager = RuntimeServiceManager(),
        runtimeInstaller: RuntimeInstaller = RuntimeInstaller(),
        flashingToolManager: FlashingToolManager = FlashingToolManager(),
        deviceBackupManager: DeviceBackupManager = DeviceBackupManager(),
        configurationInspector: ConfigurationInspector = ConfigurationInspector(),
        preferencesStore: PreferencesStore = PreferencesStore(),
        loginItemController: LoginItemController = LoginItemController(),
        deviceConfigurationStore: DeviceConfigurationStore = DeviceConfigurationStore(),
        usbDeviceDetector: USBDeviceDetector = USBDeviceDetector(),
        devicePairingManager: DevicePairingManager = DevicePairingManager(),
        asrSecretManager: any ASRSecretManaging = ASRKeychainManager(),
        asrTestService: any ASRTesting = ASRTestService(),
        asrTestAudioProvider: any ASRTestAudioProviding = ASRTestAudioGenerator()
    ) {
        self.bridgeClient = bridgeClient
        self.runtimeManager = runtimeManager
        self.runtimeInstaller = runtimeInstaller
        self.flashingToolManager = flashingToolManager
        self.deviceBackupManager = deviceBackupManager
        self.configurationInspector = configurationInspector
        self.preferencesStore = preferencesStore
        self.loginItemController = loginItemController
        self.deviceConfigurationStore = deviceConfigurationStore
        self.usbDeviceDetector = usbDeviceDetector
        self.devicePairingManager = devicePairingManager
        self.asrSecretManager = asrSecretManager
        self.asrTestService = asrTestService
        self.asrTestAudioProvider = asrTestAudioProvider
    }

    var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0.2.0-dev"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? "local"
        return "\(version) (\(build)) · M4-4C"
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        startStartupSmokeProbeIfRequested()

        Task {
            async let loadedPreferences = preferencesStore.load()
            async let loadedDeviceConfiguration = deviceConfigurationStore.load()
            configuration = await loadedPreferences
            asrDraft = configuration.asr ?? .standard
            deviceConfiguration = await loadedDeviceConfiguration
            synchronizeMenuBarPreference()
            configuration.launchAtLogin = await loginItemController.isEnabled()
            await refresh(forcePermissionCheck: true)
            await refreshFlashingToolStatus()
            scheduleRefreshLoop()
        }
    }

    func requestRefresh(forcePermissionCheck: Bool = false) {
        Task {
            await refresh(forcePermissionCheck: forcePermissionCheck)
        }
    }

    func markWindowVisibleForSmokeProbe() {
        startupSmokeWindowVisible = true
    }

    func refresh(forcePermissionCheck: Bool = false) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        async let bridge = bridgeClient.fetchSnapshot()
        async let inspected = configurationInspector.inspect()
        async let devices = bridgeClient.fetchDevices()
        async let usbDevice = usbDeviceDetector.detect()

        let fetchedBridge = await bridge
        let fetchedConfiguration = await inspected
        let fetchedDevices = await devices
        let detectedUSBDevice = await usbDevice
        let runtime = await runtimeManager.snapshot(
            bridge: fetchedBridge,
            forcePermissionCheck: forcePermissionCheck
        )

        bridgeSnapshot = fetchedBridge
        runtimeSnapshot = runtime
        configurationSummary = fetchedConfiguration.legacy
        keychainSummary = fetchedConfiguration.keychain
        voiceInteractionSummary = fetchedConfiguration.voice
        if configuration.asr == nil,
           !hasEditedASRDraft,
           let provider = ASRProvider.fromLegacyID(fetchedConfiguration.legacy.asrProvider) {
            asrDraft = .preset(provider)
        }
        bridgeDevices = fetchedDevices
        if case .pairing = pairingPhase {
            // Preserve the in-flight phase until the USB transaction finishes.
        } else if case .paired = pairingPhase {
            // Keep the success result visible until the user explicitly checks USB again.
        } else if let detectedUSBDevice {
            pairingPhase = .ready(detectedUSBDevice)
        } else {
            pairingPhase = .unavailable("未检测到 StickS3 USB 连接")
        }
    }

    func detectUSBDevice() {
        guard pairingPhase != .detecting else { return }
        pairingPhase = .detecting
        Task {
            if let candidate = await usbDeviceDetector.detect() {
                pairingPhase = .ready(candidate)
            } else {
                pairingPhase = .unavailable("未检测到 StickS3；请确认使用 USB-C 数据线")
            }
        }
    }

    func pairDetectedDevice() {
        guard case .ready(let candidate) = pairingPhase else { return }
        guard bridgeSnapshot.isM2PairingReady else {
            presentedMessage = AppMessage(
                title: "暂不写入配对密钥",
                message: "当前运行的 Bridge 尚未载入 M2 协议。请先安装或启动经过验证的 M2 Bridge，再执行 USB 配对；现有固件与旧 token 保持不变。"
            )
            return
        }
        pairingPhase = .pairing
        Task {
            do {
                let identity = try await devicePairingManager.pair(
                    candidate: candidate,
                    fallbackHost: configuration.manualBridgeAddress
                )
                pairingPhase = .paired(identity)
                presentedMessage = AppMessage(
                    title: "安全配对完成",
                    message: "设备身份与专属密钥已写入；明文密钥未进入配置文件。Bridge 将通过 Bonjour 自动发现，手动地址只作回退。"
                )
                await refresh()
            } catch {
                pairingPhase = .unavailable(error.localizedDescription)
                presentedMessage = AppMessage(title: "配对未完成", message: error.localizedDescription)
            }
        }
    }

    func setDeviceModule(_ module: DeviceModule, enabled: Bool) {
        guard module != .codex, module != .connection else { return }
        var value = deviceConfiguration
        if enabled {
            if !value.modules.contains(module) { value.modules.append(module) }
        } else {
            value.modules.removeAll { $0 == module }
            if value.defaultPage == module { value.defaultPage = .codex }
        }
        deviceConfiguration = value.normalized
    }

    func setProjectVisibility(_ visible: Bool) {
        deviceConfiguration.project.visible = visible
    }

    func setProjectName(_ name: String) {
        var value = String(name.prefix(18))
        while value.utf8.count > 39 {
            value.removeLast()
        }
        deviceConfiguration.project.name = value
    }

    func setFrontDoublePressAction(_ action: FrontDoublePressAction) {
        deviceConfiguration.buttons.frontDouble = action
    }

    func setSidePressAction(_ action: SidePressAction) {
        deviceConfiguration.buttons.sideSingle = action
    }

    func saveDeviceConfiguration() {
        guard !deviceConfigurationSaveInProgress else { return }
        deviceConfigurationSaveInProgress = true
        let requested = deviceConfiguration
        Task {
            do {
                deviceConfiguration = try await deviceConfigurationStore.save(requested)
                deviceConfigurationSaveInProgress = false
                presentedMessage = AppMessage(
                    title: "设置已保存",
                    message: "配置修订版 \(deviceConfiguration.revision) 已交给 Bridge；已配对设备在线时会自动拉取并确认。"
                )
                await refresh()
            } catch {
                deviceConfigurationSaveInProgress = false
                presentedMessage = AppMessage(title: "设备设置未保存", message: error.localizedDescription)
            }
        }
    }

    func selectASRProvider(_ provider: ASRProvider) {
        asrDraft = .preset(provider)
        noteASRDraftChanged()
    }

    func setASRBaseURL(_ value: String) {
        asrDraft.baseURL = value
        noteASRDraftChanged()
    }

    func setASRModel(_ value: String) {
        asrDraft.model = value
        noteASRDraftChanged()
    }

    func setASRLanguage(_ value: String) {
        asrDraft.language = value
        noteASRDraftChanged()
    }

    func setASRLocalCommand(_ value: String) {
        asrDraft.localCommand = value
        noteASRDraftChanged()
    }

    func saveASRConfiguration(apiKey: String) {
        guard !asrSettingsSaveInProgress else { return }
        asrSettingsSaveInProgress = true
        let requested = asrDraft
        let suppliedKey = requested.provider.isCloud
            ? apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            : ""

        Task {
            do {
                let validated = try requested.validated()
                let hasStoredKey = validated.provider.isCloud
                    ? await asrSecretManager.containsAPIKey()
                    : false
                if validated.requiresAPIKey && suppliedKey.isEmpty && !hasStoredKey {
                    throw ASRConfigurationError.missingAPIKey
                }

                var value = configuration
                value.asr = validated
                try await preferencesStore.save(value)
                if !suppliedKey.isEmpty {
                    do {
                        try await asrSecretManager.saveAPIKey(suppliedKey)
                    } catch {
                        try? await preferencesStore.save(configuration)
                        throw error
                    }
                }

                configuration = value
                asrDraft = validated
                hasEditedASRDraft = false
                asrSettingsSaveInProgress = false
                presentedMessage = AppMessage(
                    title: "语音供应方已保存",
                    message: validated.provider == .localCommand
                        ? "命令配置已写入私有应用数据；保存过程没有执行命令，也没有触碰当前输入框。"
                        : "非敏感配置已写入私有应用数据，API Key 只保存在 macOS 钥匙串。M3-C Bridge 会在下一次录音时读取配置；保存不会重启后台服务。"
                )
                await refresh()
            } catch {
                asrSettingsSaveInProgress = false
                presentedMessage = AppMessage(title: "语音供应方未保存", message: error.localizedDescription)
            }
        }
    }

    func deleteASRAPIKey() {
        guard !asrSettingsSaveInProgress else { return }
        asrSettingsSaveInProgress = true
        Task {
            do {
                try await asrSecretManager.deleteAPIKey()
                asrSettingsSaveInProgress = false
                presentedMessage = AppMessage(
                    title: "语音 API Key 已移除",
                    message: "钥匙串条目已删除；供应方和模型等非敏感设置仍保留。"
                )
                await refresh()
            } catch {
                asrSettingsSaveInProgress = false
                presentedMessage = AppMessage(title: "API Key 未移除", message: error.localizedDescription)
            }
        }
    }

    func runASRProviderTest(apiKey: String) {
        guard !isASRTestBusy else { return }
        let configuration: ASRConfiguration
        do {
            configuration = try asrDraft.validated()
        } catch {
            asrTestFeedback = .failure("配置尚未就绪", detail: error.localizedDescription)
            return
        }
        asrTestFeedback = ASRTestFeedback(
            phase: .testing,
            title: "正在测试 \(configuration.provider.title)",
            detail: configuration.provider.isCloud
                ? "正在生成固定样本“\(ASRTestAudioFixture.expectedTranscript)”并发送到 \(configuration.targetHost ?? "所选供应方")；不会访问麦克风或注入当前输入框。"
                : "正在生成固定样本“\(ASRTestAudioFixture.expectedTranscript)”并交给本地命令；不会访问麦克风或注入当前输入框。",
            transcriptPreview: nil
        )

        let suppliedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                let fixture = try await asrTestAudioProvider.makeFixture()
                defer { try? FileManager.default.removeItem(at: fixture.audioURL) }
                let storedKey = configuration.requiresAPIKey && suppliedKey.isEmpty
                    ? try await asrSecretManager.storedAPIKey()
                    : nil
                if configuration.requiresAPIKey && suppliedKey.isEmpty && storedKey == nil {
                    throw ASRConfigurationError.missingAPIKey
                }
                asrTestFeedback = await asrTestService.test(
                    audioURL: fixture.audioURL,
                    expectedTranscript: fixture.expectedTranscript,
                    configuration: configuration,
                    apiKey: suppliedKey.isEmpty ? storedKey : suppliedKey
                )
            } catch {
                asrTestFeedback = .failure("供应方测试失败", detail: error.localizedDescription)
            }
        }
    }

    var isASRTestBusy: Bool {
        asrTestFeedback.phase == .testing
    }

    var hasConfiguredASR: Bool {
        configuration.asr != nil || configurationSummary.asrConfigurationDetected
    }

    private func noteASRDraftChanged() {
        hasEditedASRDraft = true
        guard !isASRTestBusy else { return }
        asrTestFeedback = .idle
    }

    func setManualBridgeAddress(_ value: String) {
        do {
            configuration.manualBridgeAddress = try ManualBridgeAddressValidator.normalized(value)
            persistConfiguration()
        } catch {
            presentedMessage = AppMessage(title: "地址未保存", message: error.localizedDescription)
        }
    }

    func performServiceAction(_ action: ServiceAction) {
        guard !serviceActionInProgress else { return }
        serviceActionInProgress = true

        Task {
            let result: ServiceActionResult
            switch action {
            case .start:
                result = await runtimeManager.startServices()
            case .restart:
                result = await runtimeManager.restartServices()
            case .stop:
                result = await runtimeManager.stopServices()
            }

            guard result.success else {
                serviceActionInProgress = false
                presentedMessage = AppMessage(title: "操作未完成", message: result.message)
                await refresh(forcePermissionCheck: true)
                return
            }

            let verified = await waitForExpectedRuntime(after: action)
            serviceActionInProgress = false
            presentedMessage = AppMessage(
                title: verified ? "操作完成" : "操作未完成",
                message: verified
                    ? result.message
                    : "系统已接收请求，但服务没有在等待时间内达到目标状态。\n\n设备连接服务：\(runtimeSnapshot.bridge.phase.label)\n屏幕提示服务：\(runtimeSnapshot.hud.phase.label)"
            )
        }
    }

    func requestRuntimeInstall() {
        let plan = RuntimeMaintenancePlanner.make(from: runtimeSnapshot)
        guard plan.allowsPayloadInstall else {
            presentedMessage = AppMessage(
                title: "当前不需要安装",
                message: plan.summary
            )
            return
        }
        runtimeInstallConfirmationPresented = true
    }

    func confirmRuntimeInstall() {
        guard !runtimeInstallInProgress else { return }
        runtimeInstallConfirmationPresented = false
        runtimeInstallInProgress = true

        Task {
            await refresh(forcePermissionCheck: false)
            let currentPlan = RuntimeMaintenancePlanner.make(from: runtimeSnapshot)
            guard currentPlan.allowsPayloadInstall else {
                runtimeInstallInProgress = false
                presentedMessage = AppMessage(
                    title: "安装未开始",
                    message: "重新检查后，当前状态不再允许安装或修复。\n\n\(currentPlan.summary)"
                )
                return
            }

            do {
                let receipt = try await runtimeInstaller.install()
                runtimeInstallInProgress = false
                await refresh(forcePermissionCheck: true)
                presentedMessage = AppMessage(
                    title: "后台组件已验证",
                    message: receipt.preservedPasteIdentity
                        ? "已安装载荷 \(receipt.payloadVersion)，并保留原有文字输入组件身份与辅助功能授权。旧运行时保存在可回退副本中。"
                        : "已安装载荷 \(receipt.payloadVersion) 并通过启动验证。文字输入组件发生变化时，macOS 可能需要重新确认辅助功能权限；旧运行时保存在可回退副本中。"
                )
            } catch {
                runtimeInstallInProgress = false
                await refresh(forcePermissionCheck: true)
                presentedMessage = AppMessage(
                    title: "安装未完成",
                    message: error.localizedDescription
                )
            }
        }
    }

    func requestFlashingToolRefresh() {
        guard !flashingToolActionInProgress, !deviceBackupActionInProgress else { return }
        Task { await refreshFlashingToolStatus() }
    }

    func requestFlashingToolDownload() {
        guard !flashingToolActionInProgress, !deviceBackupActionInProgress else { return }
        flashingToolDownloadConfirmationPresented = true
    }

    func confirmFlashingToolDownload() {
        guard !flashingToolActionInProgress, !deviceBackupActionInProgress else { return }
        flashingToolDownloadConfirmationPresented = false
        flashingToolActionInProgress = true
        flashingToolSnapshot = .checking(flashingToolSnapshot.descriptor)

        Task {
            do {
                flashingToolSnapshot = try await flashingToolManager.downloadAndVerify()
                presentedMessage = AppMessage(
                    title: "烧录工具已验证",
                    message: "\(flashingToolSnapshot.descriptor.displayName) \(flashingToolSnapshot.descriptor.version) 已保存到私有缓存，大小与 SHA-256 均匹配。M4-3 没有解包、运行工具或访问设备串口。"
                )
            } catch {
                flashingToolSnapshot = .failed(detail: error.localizedDescription)
                presentedMessage = AppMessage(
                    title: "烧录工具未就绪",
                    message: error.localizedDescription
                )
            }
            flashingToolActionInProgress = false
        }
    }

    func requestFlashingToolRemoval() {
        guard !flashingToolActionInProgress, !deviceBackupActionInProgress else { return }
        flashingToolRemovalConfirmationPresented = true
    }

    func requestFlashingToolPreparation() {
        guard !flashingToolActionInProgress,
              !deviceBackupActionInProgress,
              flashingToolSnapshot.phase == .archiveReady else { return }
        flashingToolPreparationConfirmationPresented = true
    }

    func confirmFlashingToolPreparation() {
        guard !flashingToolActionInProgress, !deviceBackupActionInProgress else { return }
        flashingToolPreparationConfirmationPresented = false
        flashingToolActionInProgress = true
        flashingToolSnapshot = .checking(flashingToolSnapshot.descriptor)

        Task {
            do {
                flashingToolSnapshot = try await flashingToolManager.prepareAndVerify()
                presentedMessage = AppMessage(
                    title: "烧录工具已准备",
                    message: "esptool \(flashingToolSnapshot.descriptor.version) 已通过固定条目、逐文件 SHA-256、Apple Silicon 架构、Espressif Developer ID 签名和离线版本检查。没有访问设备或串口。"
                )
            } catch {
                flashingToolSnapshot = .failed(detail: error.localizedDescription)
                presentedMessage = AppMessage(
                    title: "烧录工具未准备",
                    message: error.localizedDescription
                )
            }
            flashingToolActionInProgress = false
        }
    }

    func confirmFlashingToolRemoval() {
        guard !flashingToolActionInProgress, !deviceBackupActionInProgress else { return }
        flashingToolRemovalConfirmationPresented = false
        flashingToolActionInProgress = true

        Task {
            do {
                flashingToolSnapshot = try await flashingToolManager.removeCachedArchive()
                presentedMessage = AppMessage(
                    title: "工具缓存已移除",
                    message: "只删除了当前固定版本的烧录工具归档和准备目录；后台组件、配置和设备固件均未改变。"
                )
            } catch {
                presentedMessage = AppMessage(
                    title: "缓存未移除",
                    message: error.localizedDescription
                )
                await refreshFlashingToolStatus()
            }
            flashingToolActionInProgress = false
        }
    }

    private func refreshFlashingToolStatus() async {
        flashingToolSnapshot = .checking(flashingToolSnapshot.descriptor)
        flashingToolSnapshot = await flashingToolManager.inspect()
    }

    func requestDeviceInspection() {
        guard !flashingToolActionInProgress,
              !deviceBackupActionInProgress,
              flashingToolSnapshot.phase == .ready else { return }
        deviceInspectionConfirmationPresented = true
    }

    func confirmDeviceInspection() {
        guard !flashingToolActionInProgress, !deviceBackupActionInProgress else { return }
        deviceInspectionConfirmationPresented = false
        deviceBackupActionInProgress = true
        deviceBackupSnapshot = .inspecting

        Task {
            do {
                let executableURL = try await flashingToolManager.revalidatedExecutableURL()
                let inspection = try await deviceBackupManager.inspect(executableURL: executableURL)
                deviceBackupSnapshot = .ready(inspection)
                presentedMessage = AppMessage(
                    title: "设备检查通过",
                    message: "已确认 ESP32-S3、8 MiB Flash，Secure Boot 与 Flash Encryption 均未启用。设备已退出下载模式；建立备份前需要再次手动进入下载模式。"
                )
            } catch {
                deviceBackupSnapshot = .failure(error)
                presentedMessage = AppMessage(
                    title: "设备检查未通过",
                    message: error.localizedDescription
                )
                await refreshFlashingToolStatus()
            }
            deviceBackupActionInProgress = false
        }
    }

    func requestDeviceBackup() {
        guard !flashingToolActionInProgress,
              !deviceBackupActionInProgress,
              flashingToolSnapshot.phase == .ready,
              deviceBackupSnapshot.phase == .ready,
              deviceBackupSnapshot.inspection != nil else { return }
        deviceBackupConfirmationPresented = true
    }

    func confirmDeviceBackup() {
        guard !flashingToolActionInProgress,
              !deviceBackupActionInProgress,
              let expectedInspection = deviceBackupSnapshot.inspection else { return }
        deviceBackupConfirmationPresented = false
        deviceBackupActionInProgress = true
        deviceBackupSnapshot = DeviceBackupSnapshot(
            phase: .backingUp,
            detail: DeviceBackupSnapshot.backingUp.detail,
            inspection: expectedInspection,
            receipt: nil
        )

        Task {
            do {
                let executableURL = try await flashingToolManager.revalidatedExecutableURL()
                let receipt = try await deviceBackupManager.createBackup(
                    expectedInspection: expectedInspection,
                    executableURL: executableURL
                )
                deviceBackupSnapshot = .complete(receipt)
                presentedMessage = AppMessage(
                    title: "完整备份已验证",
                    message: "同一设备的两次 8 MiB 完整读取具有相同 SHA-256。已保留一份权限受限的私有备份与脱敏回执；没有擦除或写入设备。"
                )
            } catch {
                deviceBackupSnapshot = .failure(error, preserving: expectedInspection)
                presentedMessage = AppMessage(
                    title: "没有建立备份",
                    message: error.localizedDescription
                )
                await refreshFlashingToolStatus()
            }
            deviceBackupActionInProgress = false
        }
    }

    func setShowMenuBarItem(_ enabled: Bool) {
        guard configuration.showMenuBarItem != enabled else { return }
        configuration.showMenuBarItem = enabled
        persistConfiguration()
    }

    func setShowTechnicalDetails(_ enabled: Bool) {
        guard configuration.showTechnicalDetails != enabled else { return }
        configuration.showTechnicalDetails = enabled
        persistConfiguration()
    }

    func setRefreshInterval(_ seconds: Double) {
        let normalized = min(max(seconds, 5), 60)
        guard configuration.refreshIntervalSeconds != normalized else { return }
        configuration.refreshIntervalSeconds = normalized
        persistConfiguration()
        scheduleRefreshLoop()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        guard configuration.launchAtLogin != enabled else { return }
        Task {
            do {
                try await loginItemController.setEnabled(enabled)
                configuration.launchAtLogin = enabled
                persistConfiguration()
            } catch {
                presentedMessage = AppMessage(
                    title: "无法更新登录项",
                    message: error.localizedDescription
                )
            }
        }
    }

    private func persistConfiguration() {
        let value = configuration
        Task {
            do {
                try await preferencesStore.save(value)
            } catch {
                presentedMessage = AppMessage(
                    title: "设置未保存",
                    message: error.localizedDescription
                )
            }
        }
    }

    private func synchronizeMenuBarPreference() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: AppPreferenceKey.showMenuBarItem) == nil {
            defaults.set(configuration.showMenuBarItem, forKey: AppPreferenceKey.showMenuBarItem)
            return
        }

        let storedValue = defaults.bool(forKey: AppPreferenceKey.showMenuBarItem)
        guard configuration.showMenuBarItem != storedValue else { return }
        configuration.showMenuBarItem = storedValue
    }

    private func scheduleRefreshLoop() {
        refreshLoop?.cancel()
        let seconds = configuration.refreshIntervalSeconds
        refreshLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled else { return }
                await self?.refresh()
            }
        }
    }

    private func startStartupSmokeProbeIfRequested() {
        guard startupSmokeProbe == nil,
              let outputPath = ProcessInfo.processInfo.environment["VIBESTICK_SMOKE_OUTPUT"],
              !outputPath.isEmpty else {
            return
        }
        let outputURL = URL(fileURLWithPath: outputPath)
        startupSmokeObservation = objectWillChange.sink { [startupSmokeCounter] in
            startupSmokeCounter.increment()
        }
        startupSmokeProbe = Task { @MainActor in
            var sequence = 0
            while !Task.isCancelled {
                sequence += 1
                let payload: [String: Any] = [
                    "modelChanges": startupSmokeCounter.currentValue(),
                    "pid": ProcessInfo.processInfo.processIdentifier,
                    "sequence": sequence,
                    "timestamp": Date().timeIntervalSince1970,
                    "windowVisible": startupSmokeWindowVisible,
                ]
                if let data = try? JSONSerialization.data(withJSONObject: payload) {
                    try? data.write(to: outputURL, options: .atomic)
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func waitForExpectedRuntime(after action: ServiceAction) async -> Bool {
        for attempt in 0..<6 {
            if attempt > 0 {
                try? await Task.sleep(for: .milliseconds(400))
            }

            let bridge: BridgeSnapshot
            switch action {
            case .start, .restart:
                bridge = await bridgeClient.fetchSnapshot()
            case .stop:
                bridge = .empty
            }
            let runtime = await runtimeManager.snapshot(bridge: bridge, forcePermissionCheck: false)
            bridgeSnapshot = bridge
            runtimeSnapshot = runtime

            switch action {
            case .start, .restart:
                if runtime.bridge.phase == .healthy && runtime.hud.phase == .healthy {
                    return true
                }
            case .stop:
                if runtime.bridge.phase == .stopped && runtime.hud.phase == .stopped {
                    return true
                }
            }
        }
        return false
    }
}
