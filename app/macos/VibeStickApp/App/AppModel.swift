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
    @Published private(set) var configurationSummary = LegacyConfigurationSummary.empty
    @Published private(set) var keychainSummary = KeychainSummary.empty
    @Published private(set) var configuration = AppConfiguration.standard
    @Published private(set) var deviceConfiguration = DeviceConfiguration.standard
    @Published private(set) var bridgeDevices: BridgeDevicesDTO?
    @Published private(set) var pairingPhase: PairingPhase = .idle
    @Published private(set) var isRefreshing = false
    @Published private(set) var serviceActionInProgress = false
    @Published private(set) var deviceConfigurationSaveInProgress = false
    @Published var presentedMessage: AppMessage?

    private let bridgeClient: BridgeClient
    private let runtimeManager: RuntimeServiceManager
    private let configurationInspector: ConfigurationInspector
    private let preferencesStore: PreferencesStore
    private let loginItemController: LoginItemController
    private let deviceConfigurationStore: DeviceConfigurationStore
    private let usbDeviceDetector: USBDeviceDetector
    private let devicePairingManager: DevicePairingManager
    private var refreshLoop: Task<Void, Never>?
    private var startupSmokeProbe: Task<Void, Never>?
    private var startupSmokeObservation: AnyCancellable?
    private let startupSmokeCounter = StartupSmokeCounter()
    private var startupSmokeWindowVisible = false
    private var hasStarted = false

    init(
        bridgeClient: BridgeClient = BridgeClient(),
        runtimeManager: RuntimeServiceManager = RuntimeServiceManager(),
        configurationInspector: ConfigurationInspector = ConfigurationInspector(),
        preferencesStore: PreferencesStore = PreferencesStore(),
        loginItemController: LoginItemController = LoginItemController(),
        deviceConfigurationStore: DeviceConfigurationStore = DeviceConfigurationStore(),
        usbDeviceDetector: USBDeviceDetector = USBDeviceDetector(),
        devicePairingManager: DevicePairingManager = DevicePairingManager()
    ) {
        self.bridgeClient = bridgeClient
        self.runtimeManager = runtimeManager
        self.configurationInspector = configurationInspector
        self.preferencesStore = preferencesStore
        self.loginItemController = loginItemController
        self.deviceConfigurationStore = deviceConfigurationStore
        self.usbDeviceDetector = usbDeviceDetector
        self.devicePairingManager = devicePairingManager
    }

    var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0.2.0-dev"
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        startStartupSmokeProbeIfRequested()

        Task {
            async let loadedPreferences = preferencesStore.load()
            async let loadedDeviceConfiguration = deviceConfigurationStore.load()
            configuration = await loadedPreferences
            deviceConfiguration = await loadedDeviceConfiguration
            synchronizeMenuBarPreference()
            configuration.launchAtLogin = await loginItemController.isEnabled()
            await refresh(forcePermissionCheck: true)
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
