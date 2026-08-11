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
    @Published private(set) var isRefreshing = false
    @Published private(set) var serviceActionInProgress = false
    @Published var presentedMessage: AppMessage?

    private let bridgeClient: BridgeClient
    private let runtimeManager: RuntimeServiceManager
    private let configurationInspector: ConfigurationInspector
    private let preferencesStore: PreferencesStore
    private let loginItemController: LoginItemController
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
        loginItemController: LoginItemController = LoginItemController()
    ) {
        self.bridgeClient = bridgeClient
        self.runtimeManager = runtimeManager
        self.configurationInspector = configurationInspector
        self.preferencesStore = preferencesStore
        self.loginItemController = loginItemController
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
            configuration = await preferencesStore.load()
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

        let fetchedBridge = await bridge
        let fetchedConfiguration = await inspected
        let runtime = await runtimeManager.snapshot(
            bridge: fetchedBridge,
            forcePermissionCheck: forcePermissionCheck
        )

        bridgeSnapshot = fetchedBridge
        runtimeSnapshot = runtime
        configurationSummary = fetchedConfiguration.legacy
        keychainSummary = fetchedConfiguration.keychain
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
