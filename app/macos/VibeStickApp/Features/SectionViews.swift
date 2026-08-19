import SwiftUI

struct DeviceInterfaceView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                pageHeader(
                    title: "设备界面",
                    subtitle: "Codex Focus 预览已接入当前 Bridge 状态与 M2 设备配置。",
                    milestone: nil
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
                    subtitle: "状态、项目、额度、同步和按键设置来自当前 Bridge 与设备配置",
                    systemImage: "display",
                    tone: .healthy
                ) {
                    HStack(spacing: 30) {
                        VStack(spacing: 10) {
                            Label("135 × 240", systemImage: "display")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(VibeStickStyle.accent)
                            deviceMockup
                            Text(previewTelemetryLabel)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .frame(width: 180)
                        }
                        VStack(alignment: .leading, spacing: 16) {
                            Label("使用固件当前 135 × 240 坐标和卡片几何", systemImage: "ruler")
                            Label("状态、项目和额度跟随 Bridge 实时刷新", systemImage: "arrow.triangle.2.circlepath")
                            Label("单额度、双额度和陈旧标记自动重排", systemImage: "chart.bar.fill")
                            Label("Codex 图标与设备固件使用同一资源", systemImage: "checkmark.seal.fill")
                            Label("录音、识别、待发送时临时全屏覆盖", systemImage: "rectangle.inset.filled")
                            Label("设备尚未上报电量时明确显示 --%", systemImage: "battery.0percent")
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
        CodexFocusDevicePreview(preview: previewModel)
    }

    private var previewModel: CodexFocusPreviewModel {
        .make(
            bridge: model.bridgeSnapshot,
            devices: model.bridgeDevices,
            configuration: model.deviceConfiguration
        )
    }

    private var previewTelemetryLabel: String {
        if previewModel.batteryPercent == nil {
            return "实时状态与额度 · 设备电量遥测尚未开放"
        }
        return "实时状态、额度与设备电量"
    }

}

private enum CodexFocusPreviewPalette {
    static let background = Color(red: 0.020, green: 0.024, blue: 0.031)
    static let card = Color(red: 0.047, green: 0.059, blue: 0.078)
    static let border = Color(red: 0.125, green: 0.149, blue: 0.192)
    static let text = Color(red: 0.953, green: 0.957, blue: 0.965)
    static let secondary = Color(red: 0.545, green: 0.565, blue: 0.600)
    static let project = Color(red: 0.682, green: 0.706, blue: 0.749)
    static let accent = Color(red: 0.039, green: 0.518, blue: 1.000)
    static let healthy = Color(red: 0.196, green: 0.835, blue: 0.514)
    static let approval = Color(red: 0.812, green: 0.827, blue: 0.855)
    static let neutral = Color(red: 0.604, green: 0.627, blue: 0.667)
    static let dim = Color(red: 0.408, green: 0.431, blue: 0.471)
    static let barTrack = Color(red: 0.165, green: 0.176, blue: 0.200)
    static let divider = Color(red: 0.098, green: 0.114, blue: 0.141)
}

private struct CodexFocusDevicePreview: View {
    let preview: CodexFocusPreviewModel

    var body: some View {
        screen
            .frame(width: 135, height: 240)
            .scaleEffect(4.0 / 3.0, anchor: .topLeading)
            .frame(width: 180, height: 320, alignment: .topLeading)
            .shadow(color: .black.opacity(0.20), radius: 18, y: 8)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilitySummary)
    }

    private var screen: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 9)
                .fill(CodexFocusPreviewPalette.background)
            RoundedRectangle(cornerRadius: 9)
                .stroke(CodexFocusPreviewPalette.border.opacity(0.75), lineWidth: 1)
            topBar
            focusCard
            quotaCard
            footer
        }
        .clipped()
    }

    private var topBar: some View {
        ZStack(alignment: .topLeading) {
            Text(preview.wifiConnected ? "WiFi" : "OFF")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(preview.wifiConnected ? CodexFocusPreviewPalette.text : CodexFocusPreviewPalette.dim)
                .frame(width: 22, alignment: .leading)
                .offset(x: 8, y: 8)

            Circle()
                .fill(preview.bridgeConnected ? CodexFocusPreviewPalette.healthy : CodexFocusPreviewPalette.dim)
                .frame(width: 5, height: 5)
                .offset(x: 35, y: 11)

            Text(preview.batteryText)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(CodexFocusPreviewPalette.text)
                .frame(width: 26, alignment: .trailing)
                .offset(x: 72, y: 8)

            batteryIcon
                .offset(x: 101, y: 8)
        }
    }

    private var batteryIcon: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 3)
                .stroke(CodexFocusPreviewPalette.text, lineWidth: 1)
                .frame(width: 26, height: 13)
            if let batteryPercent = preview.batteryPercent {
                RoundedRectangle(cornerRadius: 2)
                    .fill(CodexFocusPreviewPalette.text)
                    .frame(width: max(1, 20 * CGFloat(batteryPercent) / 100), height: 9)
                    .offset(x: 2)
            }
            RoundedRectangle(cornerRadius: 1)
                .fill(CodexFocusPreviewPalette.text)
                .frame(width: 2, height: 7)
                .offset(x: 28)
        }
        .frame(width: 31, height: 13, alignment: .leading)
    }

    private var focusCard: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 9)
                .fill(CodexFocusPreviewPalette.card)
                .overlay {
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(CodexFocusPreviewPalette.border, lineWidth: 1)
                }
                .frame(width: 119, height: 81)
                .offset(x: 8, y: 30)

            Image("CodexDeviceIcon")
                .resizable()
                .interpolation(.none)
                .frame(width: preview.project == nil ? 36 : 32, height: preview.project == nil ? 36 : 32)
                .offset(x: preview.project == nil ? 13 : 17, y: preview.project == nil ? 49 : 46)

            VStack(spacing: 1) {
                Text("CODEX")
                    .font(.system(size: 10, weight: .medium))
                    .tracking(1)
                    .foregroundStyle(CodexFocusPreviewPalette.project)
                HStack(spacing: 4) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 5, height: 5)
                    Text(preview.statusText)
                        .font(.system(size: 16, weight: .semibold))
                        .tracking(preview.statusText.utf8.count > 6 ? 0 : 1)
                        .foregroundStyle(CodexFocusPreviewPalette.text)
                }
            }
            .fixedSize()
            .frame(width: 70, alignment: .trailing)
            .offset(x: 49, y: preview.project == nil ? 51 : 46)

            if let project = preview.project {
                HStack(spacing: 4) {
                    Circle()
                        .fill(CodexFocusPreviewPalette.accent)
                        .frame(width: 3, height: 3)
                    Text(project)
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(1)
                        .foregroundStyle(CodexFocusPreviewPalette.project)
                }
                .frame(maxWidth: 94)
                .fixedSize()
                .frame(width: 119)
                .offset(x: 8, y: 88)
            }
        }
    }

    private var quotaCard: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 9)
                .fill(CodexFocusPreviewPalette.card)
                .overlay {
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(CodexFocusPreviewPalette.border, lineWidth: 1)
                }
                .frame(width: 119, height: 88)
                .offset(x: 8, y: 116)

            switch preview.quotaWindows.count {
            case 0:
                Text("WAIT")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(CodexFocusPreviewPalette.dim)
                    .frame(width: 84)
                    .offset(x: 25, y: 158)
            case 1:
                singleQuota(preview.quotaWindows[0])
            default:
                Rectangle()
                    .fill(CodexFocusPreviewPalette.border)
                    .frame(width: 1, height: 61)
                    .offset(x: 67, y: 130)
                dualQuota(preview.quotaWindows[0], left: true)
                dualQuota(preview.quotaWindows[1], left: false)
            }
        }
    }

    private func singleQuota(_ window: CodexFocusPreviewQuotaWindow) -> some View {
        ZStack(alignment: .topLeading) {
            Text(quotaTitle(window, single: true))
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(CodexFocusPreviewPalette.secondary)
                .frame(width: 101, alignment: .leading)
                .offset(x: 17, y: 122)
            Text("LEFT")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(CodexFocusPreviewPalette.secondary)
                .frame(width: 36, alignment: .trailing)
                .offset(x: 82, y: 123)
            Text(quotaValue(window))
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(CodexFocusPreviewPalette.text)
                .frame(width: 96)
                .offset(x: 20, y: 145)
            quotaBar(window, width: 101)
                .offset(x: 17, y: 183)
        }
    }

    private func dualQuota(_ window: CodexFocusPreviewQuotaWindow, left: Bool) -> some View {
        let titleX: CGFloat = left ? 16 : 75
        let valueX: CGFloat = left ? 10 : 71
        let barX: CGFloat = left ? 18 : 77
        return ZStack(alignment: .topLeading) {
            Text(quotaTitle(window, single: false))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(CodexFocusPreviewPalette.secondary)
                .frame(width: 44)
                .offset(x: titleX, y: 123)
            Text(quotaValue(window))
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(CodexFocusPreviewPalette.text)
                .frame(width: 54)
                .offset(x: valueX, y: 145)
            quotaBar(window, width: 40)
                .offset(x: barX, y: 183)
        }
    }

    private func quotaBar(_ window: CodexFocusPreviewQuotaWindow, width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 3)
                .fill(CodexFocusPreviewPalette.barTrack)
            if let value = window.remainingPercent {
                RoundedRectangle(cornerRadius: 3)
                    .fill(CodexFocusPreviewPalette.accent)
                    .frame(width: width * CGFloat(value) / 100)
            }
        }
        .frame(width: width, height: 5)
    }

    private var footer: some View {
        ZStack(alignment: .topLeading) {
            Circle()
                .fill(preview.syncHealthy ? CodexFocusPreviewPalette.healthy : CodexFocusPreviewPalette.dim)
                .frame(width: 3, height: 3)
                .offset(x: 9, y: 213)
            Text("SYNC")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(CodexFocusPreviewPalette.secondary)
                .frame(width: 42, alignment: .leading)
                .offset(x: 15, y: 207)
            Text(preview.footerAction)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(CodexFocusPreviewPalette.secondary)
                .frame(width: 62, alignment: .trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .allowsTightening(true)
                .offset(x: 65, y: 207)
            Rectangle()
                .fill(CodexFocusPreviewPalette.divider)
                .frame(width: 119, height: 1)
                .offset(x: 8, y: 222)
            Text("HOLD TO SPEAK")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(CodexFocusPreviewPalette.project)
                .frame(width: 119)
                .offset(x: 8, y: 225)
        }
    }

    private var statusColor: Color {
        switch preview.statusTone {
        case .accent: CodexFocusPreviewPalette.accent
        case .approval: CodexFocusPreviewPalette.approval
        case .neutral: CodexFocusPreviewPalette.neutral
        case .dim: CodexFocusPreviewPalette.dim
        }
    }

    private func quotaTitle(_ window: CodexFocusPreviewQuotaWindow, single: Bool) -> String {
        window.label + (single ? "" : " 剩余") + (window.stale ? "*" : "")
    }

    private func quotaValue(_ window: CodexFocusPreviewQuotaWindow) -> String {
        window.remainingPercent.map { "\($0)%" } ?? "--%"
    }

    private var accessibilitySummary: String {
        let quota = preview.quotaWindows.map { "\($0.label) \(quotaValue($0))" }.joined(separator: "，")
        return "Codex Focus，\(preview.statusText)，项目 \(preview.project ?? "隐藏")，\(quota.isEmpty ? "额度不可用" : quota)，电量 \(preview.batteryText)"
    }
}

struct VoiceAndSendView: View {
    @EnvironmentObject private var model: AppModel
    @State private var apiKey = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                pageHeader(
                    title: "语音与发送",
                    subtitle: "原生配置 ASR；测试结果只留在本页，不进入当前输入框。",
                    milestone: nil,
                    currentMilestone: "M3-C"
                )

                StatusCard(
                    title: "当前语音链路",
                    subtitle: "只读取脱敏摘要，不读取或显示 API Key",
                    systemImage: "waveform.circle.fill",
                    tone: model.hasConfiguredASR ? .neutral : .warning
                ) {
                    LabeledContent(
                        "配置状态",
                        value: model.hasConfiguredASR ? "已发现本地配置" : "未发现"
                    )
                    LabeledContent("识别供应方", value: providerLabel)
                    LabeledContent("识别后的发送方式", value: model.configurationSummary.voiceSendMode.title)
                    LabeledContent("Bridge 语音协议", value: bridgeVoiceProtocolLabel)
                    LabeledContent("文字输入服务", value: model.runtimeSnapshot.paste.phase.label)
                    Text(model.configurationSummary.voiceSendMode.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                StatusCard(
                    title: "原生供应方配置",
                    subtitle: "非敏感设置写入 0600 应用数据，API Key 只进入 macOS 钥匙串",
                    systemImage: "key.horizontal.fill",
                    tone: model.hasConfiguredASR ? .neutral : .warning
                ) {
                    Picker("供应方", selection: providerBinding) {
                        ForEach(ASRProvider.allCases) { provider in
                            Text(provider.title).tag(provider)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text(model.asrDraft.provider.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if model.asrDraft.provider == .localCommand {
                        TextField("本地转写命令", text: localCommandBinding)
                            .textFieldStyle(.roundedBorder)
                        Text("命令从 stdin 接收含 audio_file 与 test_only 的 JSON；测试时也会提供 VIBE_STICK_TEST_AUDIO。最终转写写到 stdout。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        TextField("Base URL 或完整 /audio/transcriptions 地址", text: baseURLBinding)
                            .textFieldStyle(.roundedBorder)
                        TextField("模型", text: modelBinding)
                            .textFieldStyle(.roundedBorder)
                        TextField("语言（可选，例如 zh）", text: languageBinding)
                            .textFieldStyle(.roundedBorder)
                        SecureField(
                            model.legacyKeychainSummary.asrKeyStored ? "输入新 Key 可替换钥匙串中的现有 Key" : "API Key",
                            text: $apiKey
                        )
                        .textFieldStyle(.roundedBorder)

                        HStack {
                            Label(
                                model.legacyKeychainSummary.asrKeyStored ? "钥匙串中已有语音 Key" : "钥匙串中尚无语音 Key",
                                systemImage: model.legacyKeychainSummary.asrKeyStored ? "checkmark.shield.fill" : "key.slash"
                            )
                            .foregroundStyle(model.legacyKeychainSummary.asrKeyStored ? .green : .secondary)
                            Spacer()
                            if model.legacyKeychainSummary.asrKeyStored {
                                Button("移除 Key", role: .destructive) {
                                    model.deleteASRAPIKey()
                                }
                                .disabled(model.asrSettingsSaveInProgress)
                            }
                        }
                        .font(.caption)
                    }

                    Divider()

                    HStack {
                        Button {
                            model.saveASRConfiguration(apiKey: apiKey)
                            apiKey = ""
                        } label: {
                            if model.asrSettingsSaveInProgress {
                                ProgressView().controlSize(.small)
                            } else {
                                Label("保存供应方配置", systemImage: "square.and.arrow.down")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.asrSettingsSaveInProgress || model.isASRTestBusy)
                        Spacer()
                        Text(model.asrDraft.provider.isCloud ? cloudDisclosure : "音频不会离开这台 Mac")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                StatusCard(
                    title: "独立供应方测试",
                    subtitle: "固定音频回环；不访问麦克风、Paste Helper、剪贴板或 Return",
                    systemImage: testSystemImage,
                    tone: testTone
                ) {
                    LabeledContent("测试状态", value: model.asrTestFeedback.title)
                    LabeledContent("期望文字", value: ASRTestAudioFixture.expectedTranscript)
                    if model.asrDraft.provider.isCloud {
                        LabeledContent("音频目标", value: model.asrDraft.targetHost ?? "请先填写有效地址")
                    } else {
                        LabeledContent("音频目标", value: "本机命令")
                    }
                    Text(model.asrTestFeedback.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let transcript = model.asrTestFeedback.transcriptPreview {
                        Text("测试识别结果")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(transcript)
                            .textSelection(.enabled)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                        Text("结果只存在于当前 App 会话内存，不写入配置或录音状态。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Button {
                            model.runASRProviderTest(apiKey: apiKey)
                        } label: {
                            if model.asrTestFeedback.phase == .testing {
                                ProgressView().controlSize(.small)
                            } else {
                                Label("提交固定音频测试", systemImage: "waveform.badge.magnifyingglass")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.asrTestFeedback.phase == .testing)
                        Spacer()
                        Text("不注入 · 不按 Return")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.green)
                    }
                }

                StatusCard(
                    title: "最近一次设备语音",
                    subtitle: "M3-B 只读摘要；不显示转写正文、窗口标题或目标指纹",
                    systemImage: voiceStatusSystemImage,
                    tone: model.voiceInteractionSummary.tone
                ) {
                    LabeledContent("结果", value: model.voiceInteractionSummary.title)
                    LabeledContent("会话模式", value: model.voiceInteractionSummary.sendMode.title)
                    if let stoppedAt = model.voiceInteractionSummary.stoppedAt {
                        LabeledContent("完成时间", value: stoppedAt)
                    }
                    Text(model.voiceInteractionSummary.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(30)
            .frame(maxWidth: 920, alignment: .leading)
        }
        .navigationTitle("语音与发送")
    }

    private var providerBinding: Binding<ASRProvider> {
        Binding(
            get: { model.asrDraft.provider },
            set: { value in model.selectASRProvider(value) }
        )
    }

    private var baseURLBinding: Binding<String> {
        Binding(get: { model.asrDraft.baseURL }, set: { value in model.setASRBaseURL(value) })
    }

    private var modelBinding: Binding<String> {
        Binding(get: { model.asrDraft.model }, set: { value in model.setASRModel(value) })
    }

    private var languageBinding: Binding<String> {
        Binding(get: { model.asrDraft.language }, set: { value in model.setASRLanguage(value) })
    }

    private var localCommandBinding: Binding<String> {
        Binding(get: { model.asrDraft.localCommand }, set: { value in model.setASRLocalCommand(value) })
    }

    private var providerLabel: String {
        if let native = model.configuration.asr { return native.provider.title }
        return switch model.configurationSummary.asrProvider?.lowercased() {
        case "groq": "Groq"
        case "siliconflow", "silicon-flow": "硅基流动"
        case "openai-compatible": "OpenAI-compatible"
        case let value?: value
        case nil: "尚未选择"
        }
    }

    private var cloudDisclosure: String {
        guard let host = model.asrDraft.targetHost else { return "保存前请检查音频目标" }
        return "测试音频将发送到 \(host)"
    }

    private var testTone: HealthTone {
        switch model.asrTestFeedback.phase {
        case .success: .healthy
        case .failure: .warning
        case .testing: .neutral
        case .idle: .inactive
        }
    }

    private var testSystemImage: String {
        switch model.asrTestFeedback.phase {
        case .success: "checkmark.circle.fill"
        case .failure: "exclamationmark.triangle.fill"
        case .testing: "waveform.badge.magnifyingglass"
        case .idle: "waveform"
        }
    }

    private var bridgeVoiceProtocolLabel: String {
        guard model.bridgeSnapshot.isHealthy else { return "Bridge 当前不可用" }
        guard let version = model.bridgeSnapshot.health?.voiceInteractionVersion else {
            return "兼容模式 v1"
        }
        return version >= 2 ? "v\(version) · 蓝键确认已就绪" : "兼容模式 v\(version)"
    }

    private var voiceStatusSystemImage: String {
        switch model.voiceInteractionSummary.tone {
        case .healthy: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .neutral: "waveform.circle.fill"
        case .inactive: "minus.circle.fill"
        }
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
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                pageHeader(
                    title: "更新与恢复",
                    subtitle: "M4-4D D0.2 补齐首次 Wi-Fi 安全配网，并保留 D0.1 的即时 NVS 与恢复门禁。",
                    milestone: nil
                )

                StatusCard(
                    title: "Mac 后台安装与修复",
                    subtitle: "先预检；只有单独确认后才暂存、备份、切换、启动验证，并在失败时回退",
                    systemImage: maintenanceSystemImage,
                    tone: maintenanceTone
                ) {
                    HStack {
                        PhasePill(text: maintenanceLabel, tone: maintenanceTone)
                        Spacer()
                        Button("重新检查") {
                            model.requestRefresh(forcePermissionCheck: true)
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.isRefreshing || model.runtimeInstallInProgress)
                    }

                    Text(maintenancePlan.summary)
                        .foregroundStyle(.secondary)

                    VStack(spacing: 2) {
                        ServiceStatusRow(
                            component: model.runtimeSnapshot.bridge,
                            showTechnicalDetails: model.configuration.showTechnicalDetails
                        )
                        Divider()
                        ServiceStatusRow(
                            component: model.runtimeSnapshot.hud,
                            showTechnicalDetails: model.configuration.showTechnicalDetails
                        )
                        Divider()
                        ServiceStatusRow(
                            component: model.runtimeSnapshot.paste,
                            showTechnicalDetails: model.configuration.showTechnicalDetails
                        )
                    }

                    if !maintenancePlan.actions.isEmpty {
                        Divider()
                        VStack(alignment: .leading, spacing: 9) {
                            Text("下一步计划")
                                .font(.subheadline.weight(.semibold))
                            ForEach(maintenancePlan.actions, id: \.rawValue) { action in
                                Label(action.title, systemImage: "arrow.right.circle")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Label(
                        "只使用 App 内逐文件 SHA-256 校验的载荷；不读取仓库 .env，不执行 scripts/install.sh。",
                        systemImage: "checkmark.shield"
                    )
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if installationActionAvailable {
                        Divider()
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(runtimeInstallTitle)
                                    .font(.subheadline.weight(.semibold))
                                Text(runtimeInstallDetail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                model.requestRuntimeInstall()
                            } label: {
                                if model.runtimeInstallInProgress {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Text(runtimeInstallButtonTitle)
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.runtimeInstallInProgress || model.isRefreshing)
                        }
                    }
                }

                StatusCard(
                    title: "固件烧录工具",
                    subtitle: "按需缓存固定版本，不把完整 ESP-IDF 或工具归档塞进 DMG",
                    systemImage: "externaldrive.badge.timemachine",
                    tone: flashingToolTone
                ) {
                    HStack {
                        PhasePill(text: flashingToolLabel, tone: flashingToolTone)
                        Spacer()
                        Button("重新检查") {
                            model.requestFlashingToolRefresh()
                        }
                        .buttonStyle(.bordered)
                        .disabled(
                            model.flashingToolActionInProgress
                                || model.deviceBackupActionInProgress
                                || model.deviceFlashActionInProgress
                        )
                    }

                    Text(model.flashingToolSnapshot.detail)
                        .foregroundStyle(.secondary)

                    Label(
                        "\(model.flashingToolSnapshot.descriptor.displayName) \(model.flashingToolSnapshot.descriptor.version) · Apple Silicon · \(model.flashingToolSnapshot.descriptor.sizeLabel)",
                        systemImage: "shippingbox"
                    )
                    Label("来源：Espressif 官方 GitHub Release", systemImage: "network.badge.shield.half.filled")

                    if model.configuration.showTechnicalDetails {
                        Text("SHA-256 · \(model.flashingToolSnapshot.descriptor.sha256)")
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                    }

                    Label(
                        "下载先进入私有临时文件；HTTP、HTTPS、内容类型、大小或 SHA-256 任一不符都不会替换现有缓存。",
                        systemImage: "checkmark.shield"
                    )
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Divider()
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("M4-4B 只准备并离线验证工具")
                                .font(.subheadline.weight(.semibold))
                            Text("解包前后都会校验固定清单；只运行无设备参数的 `esptool version`，不会扫描或打开串口，也不会读取、备份或刷写固件。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()

                        if model.flashingToolActionInProgress {
                            ProgressView()
                                .controlSize(.small)
                        } else if model.flashingToolSnapshot.phase == .archiveReady {
                            Button("解包并验证…") {
                                model.requestFlashingToolPreparation()
                            }
                            .buttonStyle(.borderedProminent)
                        } else if model.flashingToolSnapshot.phase == .ready
                                    || model.flashingToolSnapshot.phase == .invalid {
                            Button("移除缓存…", role: .destructive) {
                                model.requestFlashingToolRemoval()
                            }
                            .buttonStyle(.bordered)
                        } else {
                            Button("下载并校验…") {
                                model.requestFlashingToolDownload()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }

                    Label(
                        "M4-4C 设备检查与备份、M4-4D 写入与恢复均在下方逐步确认。",
                        systemImage: "arrow.uturn.backward.circle"
                    )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                StatusCard(
                    title: "StickS3 检查与私有备份",
                    subtitle: "只读确认设备身份、安全状态和 8 MiB Flash；不会擦除或写入",
                    systemImage: "externaldrive.badge.checkmark",
                    tone: deviceBackupTone
                ) {
                    HStack {
                        PhasePill(text: deviceBackupLabel, tone: deviceBackupTone)
                        Spacer()
                        if model.deviceBackupActionInProgress {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }

                    Text(model.deviceBackupSnapshot.detail)
                        .foregroundStyle(.secondary)

                    Label(
                        "每次操作前，请长按侧面电源键，直到蓝灯双闪且屏幕熄灭，再开始。",
                        systemImage: "button.programmable"
                    )
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let inspection = model.deviceBackupSnapshot.inspection {
                        Divider()
                        Label("\(inspection.chip) · \(inspection.flashSizeLabel)", systemImage: "cpu")
                        Label("Secure Boot 关闭 · Flash Encryption 关闭", systemImage: "checkmark.shield")
                        Label("设备指纹 · \(inspection.shortFingerprint)", systemImage: "number")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }

                    if let receipt = model.deviceBackupSnapshot.receipt {
                        Label("完整镜像 · 8,388,608 字节", systemImage: "archivebox")
                        Label("两次 SHA-256 一致 · \(String(receipt.flashSHA256.prefix(16)))…", systemImage: "checkmark.seal")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        if model.configuration.showTechnicalDetails {
                            Text(receipt.backupDirectory.path)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Divider()
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("先检查，再备份")
                                .font(.subheadline.weight(.semibold))
                            Text("检查使用 ROM-only 命令；备份会完整读取两遍，只有摘要一致才保留。备份可能包含 Wi-Fi 与配对信息，因此只存放在本机私有目录。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("检查设备…") {
                            model.requestDeviceInspection()
                        }
                        .buttonStyle(.bordered)
                        .disabled(
                            model.flashingToolSnapshot.phase != .ready
                                || model.flashingToolActionInProgress
                                || model.deviceBackupActionInProgress
                                || model.deviceFlashActionInProgress
                        )
                        if model.deviceBackupSnapshot.phase == .ready {
                            Button("建立完整备份…") {
                                model.requestDeviceBackup()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(
                                model.flashingToolActionInProgress
                                    || model.deviceBackupActionInProgress
                                    || model.deviceFlashActionInProgress
                            )
                        }
                    }

                    Label(
                        "此卡仍保持 M4-4C 只读白名单；M4-4D 的写入命令位于独立执行器与独立确认流程中。",
                        systemImage: "lock.shield"
                    )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                StatusCard(
                    title: "StickS3 固件写入与恢复",
                    subtitle: "固定三个候选范围；写入、独立验证、完整恢复、恢复验证各需一次确认",
                    systemImage: "externaldrive.badge.exclamationmark",
                    tone: deviceFlashTone
                ) {
                    HStack {
                        PhasePill(text: deviceFlashLabel, tone: deviceFlashTone)
                        Spacer()
                        Button("本地复核") {
                            model.requestDeviceFlashRefresh()
                        }
                        .buttonStyle(.bordered)
                        .disabled(
                            model.flashingToolActionInProgress
                                || model.deviceBackupActionInProgress
                                || model.deviceFlashActionInProgress
                        )
                        if model.deviceFlashActionInProgress {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }

                    Text(model.deviceFlashSnapshot.detail)
                        .foregroundStyle(.secondary)

                    if let payloadVersion = model.deviceFlashSnapshot.payloadVersion {
                        Label("候选载荷 · \(payloadVersion)", systemImage: "shippingbox")
                    }
                    Label("写入范围 · 0x0 bootloader · 0x8000 partition table · 0x10000 app", systemImage: "square.stack.3d.up")
                        .font(.caption.monospaced())
                    Label("保护范围 · NVS 0x9000..<0xf000；按 0x1000 扇区边界预检", systemImage: "lock.shield")
                    Label("验证基准 · 写入命令前即时读取 0x6000 字节 NVS，私有保存并绑定事务摘要", systemImage: "clock.badge.checkmark")
                        .font(.caption.monospaced())
                    Label("正常路径不执行独立全片擦除；任何失败都不会自动重试、自动恢复或猜测设备。", systemImage: "exclamationmark.shield")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Divider()
                    HStack {
                        if [.ready, .verified, .restored].contains(model.deviceFlashSnapshot.phase) {
                            Button("写入候选固件…") {
                                model.requestCandidateFirmwareWrite()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        if model.deviceFlashSnapshot.phase == .writeUnverified {
                            Button("独立验证候选…") {
                                model.requestCandidateFirmwareVerification()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        if model.deviceFlashSnapshot.backupReady,
                           [.ready, .writeUnverified, .verified, .recoveryRequired, .restoreUnverified, .restored]
                            .contains(model.deviceFlashSnapshot.phase) {
                            Button("从完整备份恢复…", role: .destructive) {
                                model.requestDeviceRestore()
                            }
                            .buttonStyle(.bordered)
                        }
                        if model.deviceFlashSnapshot.phase == .restoreUnverified {
                            Button("独立验证恢复…") {
                                model.requestDeviceRestoreVerification()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        Spacer()
                    }
                    .disabled(
                        model.flashingToolSnapshot.phase != .ready
                            || !model.bridgeSnapshot.isHealthy
                            || model.runtimeSnapshot.bridge.phase != .healthy
                            || model.runtimeSnapshot.isRecordingActive
                            || model.flashingToolActionInProgress
                            || model.deviceBackupActionInProgress
                            || model.deviceFlashActionInProgress
                    )

                    Label(
                    "当前 D0.2 已完成逐项授权的候选写入/读回、首次 Wi-Fi 配网和真实语音蓝键发送验收；任何新的设备写入、恢复或发布仍必须获得新的逐项授权。",
                        systemImage: "hammer"
                    )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(30)
            .frame(maxWidth: 920, alignment: .leading)
        }
        .navigationTitle("更新与恢复")
        .confirmationDialog(
            "安装、修复或重新安装 VibeStick 后台组件？",
            isPresented: $model.runtimeInstallConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("继续并保留回退副本") {
                model.confirmRuntimeInstall()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("确认后会短暂停止受管 Bridge 与 HUD，验证 DMG 内载荷，备份现有安装，再启动并检查新组件。任何验证失败都会尝试恢复旧运行时和原服务状态。")
        }
        .confirmationDialog(
            "下载并校验固定版本的烧录工具？",
            isPresented: $model.flashingToolDownloadConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("下载 \(model.flashingToolSnapshot.descriptor.sizeLabel) 并校验") {
                model.confirmFlashingToolDownload()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将从 Espressif 官方 GitHub 下载 esptool \(model.flashingToolSnapshot.descriptor.version) 的 Apple Silicon 归档。只有 HTTPS、大小和 SHA-256 全部匹配时才写入私有缓存；不会解包、运行或访问设备。")
        }
        .confirmationDialog(
            "解包并离线验证固定烧录工具？",
            isPresented: $model.flashingToolPreparationConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("解包并验证 esptool \(model.flashingToolSnapshot.descriptor.version)") {
                model.confirmFlashingToolPreparation()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只会把已通过大小和 SHA-256 校验的固定归档解到私有版本目录，随后检查精确文件集、内部摘要、纯 Apple Silicon 架构、Espressif Developer ID 签名，并运行不带端口参数的 `esptool version`。不会扫描或打开串口，也不会读取、备份、擦除或写入设备。")
        }
        .confirmationDialog(
            "只读检查 StickS3？",
            isPresented: $model.deviceInspectionConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("检查身份与安全状态") {
                model.confirmDeviceInspection()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("请先让设备进入下载模式。确认后只运行 ROM-only 的固定身份、安全状态、Flash 容量与 MAC 读取；MAC 只用于生成 SHA-256 设备指纹，不会明文保存。操作结束会让设备重新启动，不会擦除或写入 Flash。")
        }
        .confirmationDialog(
            "建立私有 8 MiB 完整备份？",
            isPresented: $model.deviceBackupConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("读取两遍并验证") {
                model.confirmDeviceBackup()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("请再次让同一设备进入下载模式。确认后会复查身份与安全状态，再用 ROM-only read-flash 完整读取两遍；只有两份 SHA-256 一致才保留一份。备份含完整设备内容，可能包括 Wi-Fi 和配对信息，仅保存到权限 0700/0600 的本机私有目录。不会擦除或写入设备。")
        }
        .confirmationDialog(
            "写入 M4-4D 候选固件？",
            isPresented: $model.candidateFirmwareWriteConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("只写入三个固定范围", role: .destructive) {
                model.confirmCandidateFirmwareWrite()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("请让已建立 M4-4C 完整备份的同一设备进入下载模式。确认后会重新核对设备身份、安全状态、载荷摘要与扇区边界，先即时读取并私密保存 NVS 快照，再只写入 0x0、0x8000、0x10000 三个范围。写入可能使设备无法启动；不会执行独立全片擦除，也不会自动重试、验证或恢复。")
        }
        .confirmationDialog(
            "独立读回验证候选固件？",
            isPresented: $model.candidateFirmwareVerificationConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("读回候选范围与 NVS") {
                model.confirmCandidateFirmwareVerification()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("设备应继续停在下载模式。确认后会重新核对同一设备，逐项读回三个固件范围并与候选摘要比较，同时把 NVS 与紧邻候选写入前保存的私有快照比较；最后才复位设备。此步骤不写入 Flash，也不代替真实功能验收。")
        }
        .confirmationDialog(
            "从 M4-4C 完整备份恢复设备？",
            isPresented: $model.deviceRestoreConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("写回已验证的 8 MiB 镜像", role: .destructive) {
                model.confirmDeviceRestore()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("请让原设备进入下载模式。确认后会重新核对设备指纹、Flash ID、备份权限与摘要，再将原始 8 MiB 镜像写回 0x0。此操作会覆盖设备全部 Flash 内容；不会自动执行恢复验证，失败也不会自动重试。")
        }
        .confirmationDialog(
            "独立验证完整恢复？",
            isPresented: $model.deviceRestoreVerificationConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("完整读回 8 MiB 并比较") {
                model.confirmDeviceRestoreVerification()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("设备应继续停在下载模式。确认后会重新核对同一设备，完整读回 8 MiB 并与恢复源 SHA-256 比较，随后复位设备。此步骤不写入 Flash，也不代替恢复后的真实功能验收。")
        }
        .confirmationDialog(
            "移除本地烧录工具缓存？",
            isPresented: $model.flashingToolRemovalConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("只移除工具归档", role: .destructive) {
                model.confirmFlashingToolRemoval()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只删除 esptool \(model.flashingToolSnapshot.descriptor.version) 的固定归档和已准备目录，不影响后台组件、配置或设备固件。")
        }
    }

    private var flashingToolLabel: String {
        switch model.flashingToolSnapshot.phase {
        case .checking: "正在检查"
        case .missing: "尚未下载"
        case .archiveReady: "归档已校验"
        case .ready: "工具已准备"
        case .invalid: "缓存无效"
        case .failed: "操作失败"
        }
    }

    private var flashingToolTone: HealthTone {
        switch model.flashingToolSnapshot.phase {
        case .checking: .neutral
        case .ready: .healthy
        case .missing, .archiveReady: .inactive
        case .invalid, .failed: .warning
        }
    }

    private var deviceBackupLabel: String {
        switch model.deviceBackupSnapshot.phase {
        case .idle: "尚未检查"
        case .inspecting: "正在检查"
        case .downloadModeRequired: "需要下载模式"
        case .ready: "可以备份"
        case .backingUp: "正在备份"
        case .complete: "备份已验证"
        case .blocked: "安全门禁阻止"
        case .failed: "操作失败"
        }
    }

    private var deviceBackupTone: HealthTone {
        switch model.deviceBackupSnapshot.phase {
        case .ready, .complete: .healthy
        case .idle, .inspecting, .backingUp: .neutral
        case .downloadModeRequired: .inactive
        case .blocked, .failed: .warning
        }
    }

    private var deviceFlashLabel: String {
        switch model.deviceFlashSnapshot.phase {
        case .checking: "正在本地检查"
        case .ready: "本地门禁就绪"
        case .writing: "正在写入"
        case .writeUnverified: "写入待独立验证"
        case .verifying: "正在验证候选"
        case .verified: "候选读回一致"
        case .recoveryRequired: "需要人工恢复决定"
        case .restoring: "正在恢复"
        case .restoreUnverified: "恢复待独立验证"
        case .verifyingRestore: "正在验证恢复"
        case .restored: "恢复读回一致"
        case .blocked: "本地门禁阻止"
        case .failed: "操作失败"
        }
    }

    private var deviceFlashTone: HealthTone {
        switch model.deviceFlashSnapshot.phase {
        case .ready, .verified, .restored: .healthy
        case .checking, .writing, .verifying, .restoring, .verifyingRestore: .neutral
        case .writeUnverified, .restoreUnverified: .inactive
        case .recoveryRequired, .blocked, .failed: .warning
        }
    }

    private var maintenancePlan: RuntimeMaintenancePlan {
        RuntimeMaintenancePlanner.make(from: model.runtimeSnapshot)
    }

    private var installationActionAvailable: Bool {
        maintenancePlan.allowsPayloadInstall
    }

    private var runtimeInstallTitle: String {
        switch maintenancePlan.phase {
        case .installationRequired: "安装缺少的后台组件"
        case .repairRequired: "修复受管后台组件"
        case .ready: "重新安装已验证后台组件"
        default: "管理后台组件"
        }
    }

    private var runtimeInstallDetail: String {
        if maintenancePlan.phase == .ready {
            return "仅在你主动确认时重新安装；仍会备份当前版本，且不触碰固件、钥匙串、设备登记、录音、日志或当前配置。"
        }
        return "不会触碰固件、钥匙串、设备登记、录音、日志或当前配置。"
    }

    private var runtimeInstallButtonTitle: String {
        switch maintenancePlan.phase {
        case .installationRequired: "安装…"
        case .repairRequired: "修复…"
        case .ready: "重新安装…"
        default: "继续…"
        }
    }

    private var maintenanceLabel: String {
        switch maintenancePlan.phase {
        case .checking: "正在检查"
        case .ready: "无需处理"
        case .installationRequired: "需要安装"
        case .repairRequired: "需要修复"
        case .permissionRequired: "需要授权"
        case .startRequired: "等待启动"
        case .blocked: "已安全阻断"
        }
    }

    private var maintenanceTone: HealthTone {
        switch maintenancePlan.phase {
        case .ready: .healthy
        case .checking: .neutral
        case .startRequired: .inactive
        case .installationRequired, .repairRequired, .permissionRequired, .blocked: .warning
        }
    }

    private var maintenanceSystemImage: String {
        switch maintenancePlan.phase {
        case .ready: "checkmark.seal.fill"
        case .checking: "magnifyingglass"
        case .installationRequired: "shippingbox.fill"
        case .repairRequired: "wrench.and.screwdriver.fill"
        case .permissionRequired: "hand.raised.fill"
        case .startRequired: "play.circle.fill"
        case .blocked: "exclamationmark.shield.fill"
        }
    }
}

struct AdvancedSettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                pageHeader(
                    title: "高级设置",
                    subtitle: "分别显示旧版兼容状态与迁移后的受管状态，所有内容保持脱敏。",
                    milestone: nil
                )

                StatusCard(
                    title: "配置与密钥",
                    subtitle: "旧版账户与版本化受管凭据分开显示",
                    systemImage: "key.fill",
                    tone: configurationCardTone
                ) {
                    Text("旧版兼容状态")
                        .font(.subheadline.weight(.semibold))
                    configurationSummaryRow(
                        "旧版配置文件",
                        value: model.configurationSummary.legacyFileExists ? "已找到" : "未找到",
                        tone: model.configurationSummary.legacyFileExists ? .healthy : .inactive
                    )
                    configurationSummaryRow(
                        "旧版配置包含密钥",
                        value: model.configurationSummary.containsLegacySecrets ? "是（内容已隐藏）" : "否",
                        tone: model.configurationSummary.containsLegacySecrets ? .neutral : .inactive
                    )
                    configurationSummaryRow(
                        "旧版 Bridge Token",
                        value: model.legacyKeychainSummary.bridgeTokenStored ? "已保存（保留）" : "未找到",
                        tone: model.legacyKeychainSummary.bridgeTokenStored ? .neutral : .inactive
                    )
                    configurationSummaryRow(
                        "旧版语音 Key",
                        value: model.legacyKeychainSummary.asrKeyStored ? "已保存（保留）" : "未找到",
                        tone: model.legacyKeychainSummary.asrKeyStored ? .neutral : .inactive
                    )

                    Divider()

                    Text("迁移后受管状态")
                        .font(.subheadline.weight(.semibold))
                    configurationSummaryRow(
                        "受管运行时配置",
                        value: managedConfigurationPresentation.value,
                        tone: managedConfigurationPresentation.tone
                    )
                    configurationSummaryRow(
                        "受管 Bridge 凭据",
                        value: managedCredentialPresentation(
                            model.managedRuntimeSummary.bridgeCredentialState
                        ).value,
                        tone: managedCredentialPresentation(
                            model.managedRuntimeSummary.bridgeCredentialState
                        ).tone
                    )
                    configurationSummaryRow(
                        "受管语音凭据",
                        value: managedCredentialPresentation(
                            model.managedRuntimeSummary.asrCredentialState
                        ).value,
                        tone: managedCredentialPresentation(
                            model.managedRuntimeSummary.asrCredentialState
                        ).tone
                    )
                    Text("这里只验证受管配置引用与对应凭据是否存在，不显示账户名、参数、路径或密钥内容。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

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

                LegacyMigrationCard(flow: model.legacyMigrationFlow)

                DiagnosticExportCard(flow: model.diagnosticFlow)

                StatusCard(
                    title: "关于这个开发版",
                    subtitle: "VibeStick for Mac \(model.appVersion)",
                    systemImage: "hammer.fill",
                    tone: .inactive
                ) {
                    Text("这是 VibeStick for Mac 0.2.0 RC 1：Bridge 已迁移为原生 Swift，保留 Codex Focus、语音发送、显式迁移与受管运行时。诊断预览只在主动点击后生成，诊断包只写入用户选择的本地文件夹，不包含原始日志，也不会自动上传。安装后台组件或操作设备仍需逐项确认。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(30)
            .frame(maxWidth: 920, alignment: .leading)
        }
        .navigationTitle("高级设置")
    }

    private var configurationCardTone: HealthTone {
        if model.configurationSummary.legacyFileIsOverexposed
            || model.managedRuntimeSummary.requiresAttention {
            return .warning
        }
        if model.managedRuntimeSummary.configurationState == .validated,
           model.managedRuntimeSummary.hasStoredReferencedCredentials {
            return .healthy
        }
        return .neutral
    }

    private var managedConfigurationPresentation: (value: String, tone: HealthTone) {
        switch model.managedRuntimeSummary.configurationState {
        case .notConfigured: ("尚未建立", .inactive)
        case .validated: ("已验证", .healthy)
        case .invalid: ("需要检查", .warning)
        case .unavailable: ("暂无法确认", .warning)
        }
    }

    private func managedCredentialPresentation(
        _ state: M4ManagedCredentialState
    ) -> (value: String, tone: HealthTone) {
        switch state {
        case .notReferenced: ("未由受管配置引用", .inactive)
        case .stored: ("已保存", .healthy)
        case .missing: ("已引用，但未找到", .warning)
        case .unavailable: ("暂无法确认", .warning)
        }
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

private struct DiagnosticExportCard: View {
    @ObservedObject var flow: M4DiagnosticUIFlow

    var body: some View {
        StatusCard(
            title: "导出脱敏诊断包",
            subtitle: "启动时不会生成预览；本地导出需要选择目录并再次确认",
            systemImage: "doc.badge.gearshape.fill",
            tone: tone
        ) {
            content
        }
        .alert(
            "确认导出脱敏诊断包？",
            isPresented: Binding(
                get: { flow.isAwaitingFinalConfirmation },
                set: { _ in }
            )
        ) {
            Button("导出到已选择的文件夹") {
                Task { await flow.confirmExport() }
            }
            Button("取消", role: .cancel) {
                flow.cancelFinalConfirmation()
            }
        } message: {
            if let summary = flow.finalConfirmationSummary {
                Text(summary.redactedMessage)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch flow.state {
        case .idle:
            Text("只有点击下方按钮后才读取固定结构化摘要；可选日志只读取 Bridge/HUD 的有限尾部，并在进入预览前逐行脱敏。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Toggle(
                "包含经过逐行脱敏的 Bridge/HUD 日志摘录",
                isOn: Binding(
                    get: { flow.includesRedactedLogs },
                    set: { flow.setIncludesRedactedLogs($0) }
                )
            )
            Text("不会包含原始日志、配置、钥匙串、录音、设备登记、事务文件、固件备份或完整本地路径。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("生成脱敏预览") {
                Task { await flow.preparePreview() }
            }
            .buttonStyle(.borderedProminent)

        case .preparing:
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("正在生成脱敏预览…")
                    .font(.subheadline.weight(.semibold))
            }
            Text("尚未选择保存目录，也不会在此阶段写出诊断包。")
                .font(.caption)
                .foregroundStyle(.secondary)

        case let .reviewing(review):
            previewContent(review)
            Button(review.destinationSelected ? "重新选择本地文件夹…" : "选择本地文件夹…") {
                Task { await flow.selectDestination() }
            }
            if review.destinationSelected {
                Label("已选择本地文件夹（路径保持隐藏）", systemImage: "folder.badge.checkmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
            }
            Button("复核并准备导出…") {
                _ = flow.requestFinalConfirmation()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!review.destinationSelected)
            Button("清除本次预览") {
                flow.reset()
            }
            .buttonStyle(.borderless)

        case let .awaitingFinalConfirmation(review):
            previewContent(review)
            Label("等待最终确认；尚未写入文件", systemImage: "checkmark.shield.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)

        case let .exporting(preview):
            previewContent(
                M4DiagnosticUIReview(preview: preview, destinationSelected: true)
            )
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("正在创建并验证私有本地诊断包…")
                    .font(.subheadline.weight(.semibold))
            }
            Text("不会上传，也不会控制 Bridge、HUD 或 Paste。")
                .font(.caption)
                .foregroundStyle(.secondary)

        case let .completed(receipt):
            Label("脱敏诊断包已保存", systemImage: "checkmark.seal.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.green)
            diagnosticRow("文件夹名称", value: receipt.bundleName)
            diagnosticRow("包内文件", value: "\(receipt.entryCount) 项")
            diagnosticRow("私有权限", value: receipt.privatePermissionsValidated ? "已验证" : "未确认")
            diagnosticRow("原始日志", value: receipt.includesRawLogs ? "包含" : "不包含")
            diagnosticRow("自动上传", value: receipt.uploaded ? "是" : "否")
            Button("返回诊断预览") {
                flow.reset()
            }

        case let .failed(failure):
            Label(
                failure == .previewFailed ? "无法生成脱敏预览" : "诊断包未导出",
                systemImage: "exclamationmark.shield.fill"
            )
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.orange)
            Text("操作已安全停止；这里不会显示底层路径、日志原文或错误详情。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("返回并重试") {
                flow.reset()
            }
        }
    }

    @ViewBuilder
    private func previewContent(_ review: M4DiagnosticUIReview) -> some View {
        diagnosticRow("固定 schema", value: "\(review.preview.schemaVersion)")
        diagnosticRow("预览条目", value: "\(review.preview.entries.count) 项")
        diagnosticRow("预计内容", value: "\(review.preview.totalByteCount) 字节")
        diagnosticRow(
            "脱敏日志摘录",
            value: review.preview.includesRedactedLogExcerpts ? "包含" : "不包含"
        )
        diagnosticRow("原始日志", value: review.preview.includesRawLogs ? "包含" : "不包含")
        diagnosticRow("自动上传", value: review.preview.uploadsAutomatically ? "是" : "否")

        Divider()

        Text("预览清单")
            .font(.subheadline.weight(.semibold))
        ForEach(review.preview.entries, id: \.relativePath) { entry in
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.relativePath)
                    .font(.caption.monospaced().weight(.semibold))
                Text("\(sourceTitle(entry.source)) · \(entry.byteCount) 字节")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        Text("清单只显示诊断包内的固定相对路径，不显示来源文件或本机保存路径。")
            .font(.caption2)
            .foregroundStyle(.secondary)
    }

    private var tone: HealthTone {
        switch flow.state {
        case .idle: .inactive
        case .preparing, .reviewing, .exporting: .neutral
        case .awaitingFinalConfirmation, .failed: .warning
        case .completed: .healthy
        }
    }

    private func diagnosticRow(_ title: String, value: String) -> some View {
        LabeledContent(title) {
            Text(value)
                .font(.subheadline.weight(.semibold))
        }
        .font(.subheadline)
    }

    private func sourceTitle(_ source: M4DiagnosticSourceKind) -> String {
        switch source {
        case .appMetadata: "App 元数据"
        case .operatingSystemMetadata: "系统元数据"
        case .componentHealth: "组件健康摘要"
        case .signatureStatus: "签名摘要"
        case .launchAgentStatus: "后台状态摘要"
        case .bridgeHealth: "Bridge 健康摘要"
        case .migrationReceiptSummary: "迁移回执摘要"
        case .runtimeInstallReceiptSummary: "运行时回执摘要"
        case .redactedLogExcerpt: "逐行脱敏日志摘录"
        case .rawEnvironment, .rawPreferences, .rawDeviceRegistry, .rawRecording,
             .rawLog, .keychainValue, .firmwareBackup, .firmwareTransaction:
            "禁止来源"
        }
    }
}

private struct LegacyMigrationCard: View {
    @ObservedObject var flow: M4LegacyMigrationUIFlow

    var body: some View {
        StatusCard(
            title: "迁移旧版设置",
            subtitle: "启动时不会检查；只有点击后才进行受限发现",
            systemImage: "arrow.triangle.2.circlepath.circle.fill",
            tone: tone
        ) {
            content
        }
        .alert(
            "确认执行配置迁移？",
            isPresented: Binding(
                get: { flow.isAwaitingFinalConfirmation },
                set: { _ in }
            )
        ) {
            Button("执行配置迁移", role: .destructive) {
                Task { await flow.executeMigration() }
            }
            Button("取消", role: .cancel) {
                flow.cancelFinalConfirmation()
            }
        } message: {
            if let summary = flow.finalConfirmationSummary {
                Text(summary.redactedMessage)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch flow.state {
        case .idle:
            Text("这里不会随 App 启动自动发现，也不会在后台读取旧配置或钥匙串。需要迁移时，请主动开始一次脱敏检查。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("检查可迁移的旧版设置") {
                Task { await flow.startDiscovery() }
            }
            .buttonStyle(.borderedProminent)

        case .discovering:
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("正在生成脱敏摘要…")
                    .font(.subheadline.weight(.semibold))
            }
            Text("摘要只包含设置类别、阻断原因和权限状态，不显示路径或密钥内容。")
                .font(.caption)
                .foregroundStyle(.secondary)

        case let .reviewing(review, selection):
            reviewContent(review: review, selection: selection, canEdit: true)

        case let .awaitingFinalConfirmation(review, selection):
            reviewContent(review: review, selection: selection, canEdit: false)
            Label("等待最终确认", systemImage: "checkmark.shield.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)

        case .migrating:
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("正在二次预检并执行配置迁移…")
                    .font(.subheadline.weight(.semibold))
            }
            Text("运行时激活不属于本步骤，不会启动或重启后台组件。")
                .font(.caption)
                .foregroundStyle(.secondary)

        case let .completed(receipt):
            Label("配置迁移已完成", systemImage: "checkmark.seal.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.green)
            migrationResultRow("已迁移类别", value: "\(receipt.categories.count) 项")
            migrationResultRow("旧版回退资料", value: receipt.legacyFallbackRetained ? "已保留" : "未确认")
            migrationResultRow("旧版项目删除", value: receipt.legacyItemsDeleted ? "是" : "否")
            migrationResultRow("后台组件重启", value: receipt.runtimeRestarted ? "是" : "否")
            migrationResultRow(
                "运行时激活",
                value: receipt.runtimeActivationRequired ? "需要另行授权" : "不需要"
            )
            Button("返回迁移检查") {
                flow.reset()
            }

        case let .failed(failure):
            Label(
                failure == .discoveryFailed ? "无法完成脱敏检查" : "配置迁移未完成",
                systemImage: "exclamationmark.shield.fill"
            )
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.orange)
            Text(failureDetail(failure))
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("返回并重试") {
                flow.reset()
            }
        }
    }

    @ViewBuilder
    private func reviewContent(
        review: M4LegacyMigrationUIReview,
        selection: M4LegacyMigrationUISelection,
        canEdit: Bool
    ) -> some View {
        migrationResultRow(
            "旧版配置文件",
            value: review.legacyFileExists ? "已发现（内容隐藏）" : "未发现"
        )
        if review.legacyFileExists {
            migrationResultRow(
                "旧版文件权限",
                value: review.legacyFilePermissionsArePrivate ? "仅当前用户" : "范围较宽"
            )
        }

        if !review.asrConfigurationSources.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("ASR 配置来源冲突")
                    .font(.subheadline.weight(.semibold))
                Text("当前 App 与旧 .env 都有设置，但内容不一致。这里只显示来源名称；请选择迁移时采用哪一份。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(review.asrConfigurationSources, id: \.rawValue) { source in
                    Button {
                        flow.setASRConfigurationSource(source)
                    } label: {
                        Label(
                            M4LegacyMigrationUICopy.asrConfigurationSourceTitle(source),
                            systemImage: selection.asrConfigurationSource == source
                                ? "checkmark.circle.fill"
                                : "circle"
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!canEdit)
                }
                Text("不会显示供应方参数、端点、模型、本地命令或密钥内容。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Divider()
        }

        if !review.blockers.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("当前不能迁移")
                    .font(.subheadline.weight(.semibold))
                ForEach(review.blockers, id: \.rawValue) { blocker in
                    Label(blockerTitle(blocker), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        } else if review.categories.isEmpty {
            Text("没有发现需要迁移的旧版设置。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("逐项确认要迁移的类别")
                    .font(.subheadline.weight(.semibold))
                ForEach(review.categories, id: \.rawValue) { category in
                    Toggle(
                        M4LegacyMigrationUICopy.categoryTitle(category),
                        isOn: Binding(
                            get: { selection.categories.contains(category) },
                            set: { flow.setCategory(category, selected: $0) }
                        )
                    )
                    .disabled(!canEdit)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("逐项确认受管写入目标")
                    .font(.subheadline.weight(.semibold))
                ForEach(review.requiredTargets, id: \.rawValue) { target in
                    Toggle(
                        M4LegacyMigrationUICopy.ownedTargetTitle(target),
                        isOn: Binding(
                            get: { selection.ownedTargets.contains(target) },
                            set: { flow.setOwnedTarget(target, selected: $0) }
                        )
                    )
                    .disabled(!canEdit)
                }
            }

            Label("旧版文件与旧钥匙串项目会保留", systemImage: "archivebox.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
            Label("本步骤不启动、不重启后台组件", systemImage: "pause.circle.fill")
                .font(.caption)
                .foregroundStyle(.secondary)

            if canEdit {
                Button("复核并准备迁移…") {
                    _ = flow.requestFinalConfirmation()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!selection.exactlyConfirms(review))
            }
        }

        if canEdit {
            Button("清除本次检查结果") {
                flow.reset()
            }
            .buttonStyle(.borderless)
        }
    }

    private var tone: HealthTone {
        switch flow.state {
        case .idle: .inactive
        case .discovering, .reviewing, .migrating: .neutral
        case .awaitingFinalConfirmation, .failed: .warning
        case .completed: .healthy
        }
    }

    private func migrationResultRow(_ title: String, value: String) -> some View {
        LabeledContent(title) {
            Text(value)
                .font(.subheadline.weight(.semibold))
        }
        .font(.subheadline)
    }

    private func blockerTitle(_ blocker: M4LegacyMigrationBlocker) -> String {
        switch blocker {
        case .unknownRuntimeOwner: "后台组件归属无法安全确认"
        case .activeVoiceWork: "仍有语音录制、识别或待发送工作"
        }
    }

    private func failureDetail(_ failure: M4LegacyMigrationUIFailure) -> String {
        switch failure {
        case .discoveryFailed:
            "未显示底层路径或错误详情。请先保持现有服务不变，再返回重试。"
        case .migrationFailed:
            "事务已安全停止；未显示底层路径或密钥信息。请保留旧版资料并重新检查。"
        }
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

private func pageHeader(
    title: String,
    subtitle: String,
    milestone: String?,
    currentMilestone: String? = nil
) -> some View {
    HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.largeTitle.weight(.bold))
            Text(subtitle)
                .foregroundStyle(.secondary)
        }
        Spacer()
        if let currentMilestone {
            CurrentMilestoneBadge(milestone: currentMilestone)
        } else if let milestone {
            ComingSoonBadge(milestone: milestone)
        }
    }
}
