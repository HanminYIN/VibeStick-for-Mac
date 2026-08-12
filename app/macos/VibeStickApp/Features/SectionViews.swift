import SwiftUI

struct DeviceInterfaceView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                pageHeader(
                    title: "设备界面",
                    subtitle: "M3 将已确认的 Codex Focus 布局接入真实设备配置。",
                    milestone: "M3"
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
                    Text("Codex Focus 当前固定为首页；页面拖动排序将在后续 M3 小阶段开放。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("保存并同步设备设置") {
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
                    title: "Codex Focus 实时预览",
                    subtitle: "项目名开关会同步改变预览与设备首页布局",
                    systemImage: "display",
                    tone: .healthy
                ) {
                    HStack(spacing: 30) {
                        VStack(spacing: 10) {
                            Label("135 × 240", systemImage: "display")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(VibeStickStyle.accent)
                            deviceMockup
                        }
                        VStack(alignment: .leading, spacing: 16) {
                            Label("Codex 固定为首页", systemImage: "house.fill")
                            Label("额度显示是基础能力", systemImage: "chart.bar.fill")
                            Label("单额度与 5H + 7D 双窗口自动重排", systemImage: "arrow.triangle.2.circlepath")
                            Label("有无项目名时分别平衡视觉重心", systemImage: "rectangle.3.group")
                            Label("录音、识别、待发送时临时全屏覆盖", systemImage: "rectangle.inset.filled")
                            Label("关闭的模块不会留下空白页面", systemImage: "rectangle.stack.badge.minus")
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        Spacer()
                    }
                }

                StatusCard(
                    title: "项目名称",
                    subtitle: "名称与显示开关通过 M2 安全配置通道同步",
                    systemImage: "textformat",
                    tone: .neutral
                ) {
                    Toggle(
                        "在设备首页显示项目名称",
                        isOn: Binding(
                            get: { model.deviceConfiguration.project.visible },
                            set: { model.setProjectVisibility($0) }
                        )
                    )
                    TextField(
                        "例如 VibeStick",
                        text: Binding(
                            get: { model.deviceConfiguration.project.name },
                            set: { model.setProjectName($0) }
                        )
                    )
                    .disabled(!model.deviceConfiguration.project.visible)
                    Text("留空时显示 Bridge 当前识别到的 Codex 项目；填写名称时使用固定名称。当前小屏字体优先支持英文、数字和常用符号；隐藏后状态卡会自动放大并重新平衡。")
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
        VStack(spacing: 6) {
            HStack(spacing: 5) {
                Text("WiFi")
                    .offset(y: 1)
                Circle().fill(.green).frame(width: 5, height: 5)
                Spacer()
                Text("96%")
            }
            .font(.system(size: 10, weight: .medium))

            VStack(spacing: 7) {
                HStack(spacing: 10) {
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .frame(width: 52, height: 52)
                        .foregroundStyle(.white)
                        .background(VibeStickStyle.accent, in: RoundedRectangle(cornerRadius: 15))
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("CODEX")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                            .tracking(1)
                        HStack(spacing: 5) {
                            Circle().fill(.gray).frame(width: 7, height: 7)
                            Text("待命").font(.title2.weight(.semibold))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .offset(
                        x: model.deviceConfiguration.project.visible ? -3 : 0,
                        y: model.deviceConfiguration.project.visible ? 3 : 0
                    )
                }
                if model.deviceConfiguration.project.visible {
                    Label(previewProjectName, systemImage: "circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))

            VStack(spacing: 7) {
                HStack(alignment: .firstTextBaseline) {
                    Text("7D")
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                    Text("LEFT")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(.secondary)
                Text("98%")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                ProgressView(value: 0.98).tint(VibeStickStyle.accent)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))

            HStack(spacing: 4) {
                Circle().fill(.green).frame(width: 4, height: 4)
                Text("SYNC")
                Spacer()
                Text("2X REFRESH")
            }
            .font(.system(size: 8, weight: .medium))
            .foregroundStyle(.secondary)

            Text("HOLD TO SPEAK")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(.white)
        .padding(12)
        .frame(width: 180, height: 320, alignment: .top)
        .background(Color.black, in: RoundedRectangle(cornerRadius: 22))
        .overlay {
            RoundedRectangle(cornerRadius: 22)
                .stroke(Color.white.opacity(0.16), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
    }

    private var previewProjectName: String {
        let fixedName = model.deviceConfiguration.project.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !fixedName.isEmpty { return fixedName }
        let liveName = model.bridgeSnapshot.state?.codexState?.project?.trimmingCharacters(in: .whitespacesAndNewlines)
        return liveName?.isEmpty == false ? liveName! : "VibeStick"
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
