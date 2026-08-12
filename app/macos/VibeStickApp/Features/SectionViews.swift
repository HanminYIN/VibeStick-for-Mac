import SwiftUI

struct DeviceInterfaceView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                pageHeader(
                    title: "设备界面",
                    subtitle: "M2 使用通用配置同步模块和按键；项目名称留待 M3 实装。",
                    milestone: "M2"
                )

                StatusCard(
                    title: "页面与模块",
                    subtitle: "Codex 与连接状态是基础能力，始终保留",
                    systemImage: "square.stack.3d.up.fill",
                    tone: .neutral
                ) {
                    Toggle("Codex", isOn: .constant(true))
                        .disabled(true)
                    Toggle(
                        "Claude",
                        isOn: Binding(
                            get: { model.deviceConfiguration.modules.contains(.claude) },
                            set: { model.setDeviceModule(.claude, enabled: $0) }
                        )
                    )
                    Toggle("连接状态", isOn: .constant(true))
                        .disabled(true)
                    Picker(
                        "默认页面",
                        selection: Binding(
                            get: { model.deviceConfiguration.defaultPage },
                            set: { _ in }
                        )
                    ) {
                        ForEach(model.deviceConfiguration.modules) { module in
                            Text(module.title).tag(module)
                        }
                    }
                    .disabled(true)
                    Text("M2 固定 Codex 为默认页；M3 完成页面拖动排序与实机高保真布局。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("保存并同步 M2 设置") {
                            model.saveDeviceConfiguration()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.deviceConfigurationSaveInProgress)
                        if model.deviceConfigurationSaveInProgress {
                            ProgressView().controlSize(.small)
                        }
                        Spacer()
                        Text(configurationSyncLabel)
                            .font(.caption)
                            .foregroundStyle(configurationSyncTone.color)
                    }
                    Text("设备在线后会自行拉取并 ACK；密钥、Wi-Fi 和 ASR 配置不会进入这个设置文件。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                StatusCard(
                    title: "新首页结构草图",
                    subtitle: "M3 的视觉草图；M2 不改变当前稳定屏幕布局",
                    systemImage: "display",
                    tone: .neutral
                ) {
                    HStack(spacing: 30) {
                        VStack(spacing: 10) {
                            Label("草图", systemImage: "pencil.and.outline")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.orange)
                            deviceMockup
                        }
                        VStack(alignment: .leading, spacing: 16) {
                            Label("Codex 固定为首页", systemImage: "house.fill")
                            Label("额度显示是基础能力", systemImage: "chart.bar.fill")
                            Label("M2 已接入设置同步与动态额度数据", systemImage: "arrow.triangle.2.circlepath")
                            Label("M3 完成页面排版与真实设备预览", systemImage: "rectangle.3.group")
                            Label("录音、识别、待发送时临时全屏覆盖", systemImage: "rectangle.inset.filled")
                            Label("关闭的模块不会留下空白页面", systemImage: "rectangle.stack.badge.minus")
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        Spacer()
                    }
                }

                StatusCard(
                    title: "项目名称（M3 预览）",
                    subtitle: "尚未接入实体设备屏幕，当前不会改变设备画面",
                    systemImage: "textformat",
                    tone: .inactive
                ) {
                    Label("M3 实装后可显示在 Codex 下方，并在隐藏时重新平衡版面。", systemImage: "clock.badge")
                    LabeledContent("计划支持", value: "当前项目 / 固定名称 / 隐藏")
                    Text("当前版本只保留配置协议的向后兼容性；为避免产生看似成功但没有画面效果的设置，这里暂不提供编辑入口。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(30)
            .frame(maxWidth: 920, alignment: .leading)
        }
        .navigationTitle("设备界面")
    }

    private var configurationSyncLabel: String {
        guard let device = model.bridgeDevices?.devices.first else {
            return "等待 M2 Bridge 或设备配对"
        }
        if device.lastConfigRevision == device.targetConfigRevision {
            return "设备已同步 r\(device.targetConfigRevision)"
        }
        return device.online ? "等待设备确认 r\(device.targetConfigRevision)" : "设备离线，稍后同步"
    }

    private var configurationSyncTone: HealthTone {
        guard let device = model.bridgeDevices?.devices.first else { return .inactive }
        return device.lastConfigRevision == device.targetConfigRevision ? .healthy : .warning
    }

    private var deviceMockup: some View {
        VStack(spacing: 8) {
            Text("Codex")
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Spacer()
            Text("状态区域")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white.opacity(0.65))
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("—")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text("额度")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.65))
            }
            .foregroundStyle(.white)
        }
        .padding(18)
        .frame(width: 180, height: 320)
        .background(Color.black, in: RoundedRectangle(cornerRadius: 26))
        .overlay {
            RoundedRectangle(cornerRadius: 26)
                .stroke(Color.white.opacity(0.16), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
    }

}

struct VoiceAndSendView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                pageHeader(
                    title: "语音与发送",
                    subtitle: "语音输入和额度显示属于基础能力，不会被模块化关闭。",
                    milestone: "M3"
                )

                StatusCard(
                    title: "现有语音配置",
                    subtitle: "M1 只识别是否已经配置，不读取或显示密钥",
                    systemImage: "waveform.circle.fill",
                    tone: model.configurationSummary.asrConfigurationDetected ? .neutral : .warning
                ) {
                    LabeledContent(
                        "配置状态",
                        value: model.configurationSummary.asrConfigurationDetected ? "已发现（尚未验证）" : "未发现"
                    )
                    LabeledContent("识别供应方", value: model.configurationSummary.asrProvider ?? "尚未选择")
                    LabeledContent(
                        "识别后的发送方式",
                        value: model.configurationSummary.autoEnterEnabled
                            ? "自动按下 Return"
                            : "仅粘贴；蓝键确认将在 M3 实现"
                    )
                }

                StatusCard(
                    title: "M3 的简化流程",
                    subtitle: "只需填写 API Key，再选择供应方",
                    systemImage: "wand.and.stars",
                    tone: .inactive
                ) {
                    HStack(spacing: 10) {
                        providerChip("OpenAI 兼容")
                        providerChip("Groq")
                        providerChip("硅基流动")
                        providerChip("自定义 URL")
                    }
                    Text("自定义供应方会要求 API Key、接口地址和模型名，并在保存前做连通性测试。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(30)
            .frame(maxWidth: 920, alignment: .leading)
        }
        .navigationTitle("语音与发送")
    }

    private func providerChip(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.quaternary, in: Capsule())
    }
}

struct ButtonAndReminderView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                pageHeader(
                    title: "按键与提醒",
                    subtitle: "普通状态与智能双击将分别配置，侧键只切换已启用页面。",
                    milestone: "M3"
                )

                StatusCard(
                    title: "已确定的交互规则",
                    subtitle: "作为固件二次开发的稳定约束",
                    systemImage: "button.programmable",
                    tone: .neutral
                ) {
                    ruleRow("正面蓝色键", "长按开始录音；松开结束；待发送时再按一次发送")
                    Divider()
                    ruleRow("侧面按键", "切换到下一个已启用页面；只有一个页面时不使用")
                    Divider()
                    ruleRow("智能双击", "Codex 请求审批时仅允许本次；macOS 系统权限仍在 Mac 上操作")
                }

                StatusCard(
                    title: "普通状态双击动作",
                    subtitle: "M2 配置会同步到设备；智能审批仍留在后续实验功能",
                    systemImage: "hand.tap.fill",
                    tone: .neutral
                ) {
                    Picker(
                        "正面蓝键双击",
                        selection: Binding(
                            get: { model.deviceConfiguration.buttons.frontDouble },
                            set: { model.setFrontDoublePressAction($0) }
                        )
                    ) {
                        ForEach(FrontDoublePressAction.allCases) { action in
                            Text(action.title).tag(action)
                        }
                    }
                    Picker(
                        "侧键单击",
                        selection: Binding(
                            get: { model.deviceConfiguration.buttons.sideSingle },
                            set: { model.setSidePressAction($0) }
                        )
                    ) {
                        ForEach(SidePressAction.allCases) { action in
                            Text(action.title).tag(action)
                        }
                    }
                    Button("保存并同步按键设置") {
                        model.saveDeviceConfiguration()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.deviceConfigurationSaveInProgress)
                }
            }
            .padding(30)
            .frame(maxWidth: 920, alignment: .leading)
        }
        .navigationTitle("按键与提醒")
    }

    private func ruleRow(_ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 18) {
            Text(title)
                .font(.body.weight(.semibold))
                .frame(width: 110, alignment: .leading)
            Text(detail)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 5)
    }

    private func actionChip(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.quaternary, in: Capsule())
    }
}

struct UpdatesAndRecoveryView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                pageHeader(
                    title: "更新与恢复",
                    subtitle: "M1 不会下载大型工具链，也不会碰当前设备固件。",
                    milestone: "M4"
                )

                StatusCard(
                    title: "固件与烧录",
                    subtitle: "后续按需下载，避免把一个多 GB 的完整开发环境塞进 DMG",
                    systemImage: "externaldrive.badge.timemachine",
                    tone: .inactive
                ) {
                    Label("一键下载所需工具", systemImage: "arrow.down.circle")
                    Label("选择设备页面模块并同步通用配置", systemImage: "square.stack.3d.up")
                    Label("烧录前自动备份，失败时可恢复稳定版本", systemImage: "arrow.uturn.backward.circle")
                    Text("以上按钮将在 M4 实现；当前仅展示规划，避免误操作。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(30)
            .frame(maxWidth: 920, alignment: .leading)
        }
        .navigationTitle("更新与恢复")
    }
}

struct AdvancedSettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                pageHeader(
                    title: "高级设置",
                    subtitle: "M1 建立安全存储和诊断基础，不迁移现有密钥。",
                    milestone: nil
                )

                StatusCard(
                    title: "配置与密钥",
                    subtitle: "旧配置继续生效，控制中心只显示摘要",
                    systemImage: "key.fill",
                    tone: model.configurationSummary.legacyFileIsOverexposed ? .warning : .neutral
                ) {
                    configurationSummaryRow(
                        "现有配置文件",
                        value: model.configurationSummary.legacyFileExists ? "已找到" : "未找到",
                        tone: model.configurationSummary.legacyFileExists ? .healthy : .inactive
                    )
                    configurationSummaryRow(
                        "现有配置包含密钥",
                        value: model.configurationSummary.containsLegacySecrets ? "是（内容已隐藏）" : "否",
                        tone: model.configurationSummary.containsLegacySecrets ? .neutral : .inactive
                    )
                    configurationSummaryRow(
                        "新钥匙串中的 Bridge Token",
                        value: model.keychainSummary.bridgeTokenStored ? "已保存" : "尚未迁移",
                        tone: model.keychainSummary.bridgeTokenStored ? .healthy : .warning
                    )
                    configurationSummaryRow(
                        "新钥匙串中的语音 Key",
                        value: model.keychainSummary.asrKeyStored ? "已保存" : "尚未迁移",
                        tone: model.keychainSummary.asrKeyStored ? .healthy : .warning
                    )

                    if model.configurationSummary.legacyFileIsOverexposed {
                        Label("现有 .env 的读取权限较宽。M1 仅提示，不会自动修改。", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    Button("打开本地数据文件夹（故障排查）") {
                        SystemSettingsOpener.openSupportDirectory()
                    }
                    Text("日常无需查看；遇到问题时再按提示打开，请勿自行修改或删除。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                StatusCard(
                    title: "关于这个开发版",
                    subtitle: "VibeStick for Mac \(model.appVersion)",
                    systemImage: "hammer.fill",
                    tone: .inactive
                ) {
                    Text("这是 M1 控制中心开发版，用于管理已经稳定安装的 Bridge、HUD 与 Paste。干净 Mac 的完整安装、固件下载与烧录将在后续里程碑实现。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(30)
            .frame(maxWidth: 920, alignment: .leading)
        }
        .navigationTitle("高级设置")
    }

    private func configurationSummaryRow(
        _ title: String,
        value: String,
        tone: HealthTone
    ) -> some View {
        LabeledContent {
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tone.color)
        } label: {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

struct PreferencesView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage(AppPreferenceKey.showMenuBarItem)
    private var showMenuBarItem = AppConfiguration.standard.showMenuBarItem

    var body: some View {
        Form {
            Section("应用") {
                Toggle(
                    "在菜单栏显示 VibeStick",
                    isOn: Binding(
                        get: { showMenuBarItem },
                        set: { enabled in
                            guard showMenuBarItem != enabled else { return }
                            showMenuBarItem = enabled
                            Task { @MainActor in
                                model.setShowMenuBarItem(enabled)
                            }
                        }
                    )
                )
                Toggle(
                    "登录 Mac 时自动打开",
                    isOn: Binding(
                        get: { model.configuration.launchAtLogin },
                        set: { model.setLaunchAtLogin($0) }
                    )
                )
                Toggle(
                    isOn: Binding(
                        get: { model.configuration.showTechnicalDetails },
                        set: { model.setShowTechnicalDetails($0) }
                    )
                ) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("显示故障排查信息")
                        Text("开启后会为三项后台服务补充内部名称和系统编号，方便截图排查问题；日常无需开启。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("状态刷新") {
                HStack {
                    Text("自动刷新间隔")
                    Slider(
                        value: Binding(
                            get: { model.configuration.refreshIntervalSeconds },
                            set: { model.setRefreshInterval($0) }
                        ),
                        in: 5...60,
                        step: 5
                    )
                    Text("\(Int(model.configuration.refreshIntervalSeconds)) 秒")
                        .monospacedDigit()
                        .frame(width: 45, alignment: .trailing)
                }
            }

            Section {
                Button("打开登录项系统设置") {
                    SystemSettingsOpener.openLoginItems()
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct MenuBarContentView: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("VibeStick")
                        .font(.headline)
                    Text(model.runtimeSnapshot.overallTone == .healthy ? "后台运行正常" : "有项目需要处理")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Circle()
                    .fill(model.runtimeSnapshot.overallTone.color)
                    .frame(width: 9, height: 9)
            }

            Divider()
            menuStatus(model.runtimeSnapshot.bridge)
            menuStatus(model.runtimeSnapshot.hud)
            menuStatus(model.runtimeSnapshot.paste)
            Divider()

            HStack {
                Button("打开控制中心") {
                    openWindow(id: "control-center")
                    NSApp.activate(ignoringOtherApps: true)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    model.requestRefresh(forcePermissionCheck: true)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .help("刷新")
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    private func menuStatus(_ component: ComponentHealth) -> some View {
        HStack {
            Text(component.kind.title)
            Spacer()
            Text(component.phase.label)
                .foregroundStyle(component.phase.tone.color)
        }
        .font(.caption)
    }
}

private func pageHeader(title: String, subtitle: String, milestone: String?) -> some View {
    HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.largeTitle.weight(.bold))
            Text(subtitle)
                .foregroundStyle(.secondary)
        }
        Spacer()
        if let milestone {
            ComingSoonBadge(milestone: milestone)
        }
    }
}
