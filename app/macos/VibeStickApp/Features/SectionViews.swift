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
                            model.keychainSummary.asrKeyStored ? "输入新 Key 可替换钥匙串中的现有 Key" : "API Key",
                            text: $apiKey
                        )
                        .textFieldStyle(.roundedBorder)

                        HStack {
                            Label(
                                model.keychainSummary.asrKeyStored ? "钥匙串中已有语音 Key" : "钥匙串中尚无语音 Key",
                                systemImage: model.keychainSummary.asrKeyStored ? "checkmark.shield.fill" : "key.slash"
                            )
                            .foregroundStyle(model.keychainSummary.asrKeyStored ? .green : .secondary)
                            Spacer()
                            if model.keychainSummary.asrKeyStored {
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
                    subtitle: "M4-3 可按需下载并校验轻量烧录工具；串口访问、固件备份与刷写仍未开放。",
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
                        .disabled(model.flashingToolActionInProgress)
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
                            Text("M4-3 只准备工具")
                                .font(.subheadline.weight(.semibold))
                            Text("不会解包或运行 esptool，不会扫描或打开串口，也不会读取、备份或刷写固件。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()

                        if model.flashingToolActionInProgress {
                            ProgressView()
                                .controlSize(.small)
                        } else if model.flashingToolSnapshot.phase == .ready {
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
                        "M4-4 才会加入端口识别、固件备份、更新验证与故障恢复。",
                        systemImage: "arrow.uturn.backward.circle"
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
            "移除本地烧录工具缓存？",
            isPresented: $model.flashingToolRemovalConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("只移除工具归档", role: .destructive) {
                model.confirmFlashingToolRemoval()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只删除 esptool \(model.flashingToolSnapshot.descriptor.version) 的当前缓存，不影响后台组件、配置或设备固件。")
        }
    }

    private var flashingToolLabel: String {
        switch model.flashingToolSnapshot.phase {
        case .checking: "正在检查"
        case .missing: "尚未下载"
        case .ready: "已校验"
        case .invalid: "缓存无效"
        case .failed: "下载失败"
        }
    }

    private var flashingToolTone: HealthTone {
        switch model.flashingToolSnapshot.phase {
        case .checking: .neutral
        case .ready: .healthy
        case .missing: .inactive
        case .invalid, .failed: .warning
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
                    Text("这是 M4-3 本地开发版：保留已验收的 Codex Focus、语音发送和原生 ASR 配置，并增加固定版本烧录工具的按需安全下载。当前稳定安装的 Bridge、HUD、Paste、主 App 与真机固件都不会被自动替换。")
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
