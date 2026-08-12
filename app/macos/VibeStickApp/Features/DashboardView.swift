import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var model: AppModel
    let onSelectSection: (AppSection) -> Void
    private let compactCardContentMinimumHeight: CGFloat = 64

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                codexHero
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 16, alignment: .top),
                        GridItem(.flexible(), spacing: 16, alignment: .top),
                    ],
                    spacing: 16
                ) {
                    voiceCard
                    backgroundCard
                }
                quickActions
            }
            .padding(30)
            .frame(maxWidth: 1040, alignment: .leading)
        }
        .navigationTitle("VibeStick")
        .toolbar {
            ToolbarItem {
                Button {
                    model.requestRefresh(forcePermissionCheck: true)
                } label: {
                    if model.isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(model.isRefreshing)
                .help("刷新当前状态")
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 5) {
                Text(greeting)
                    .font(.largeTitle.weight(.bold))
                Text("设备端保持原有功能，Mac 端从这里统一查看和管理。")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            PhasePill(
                text: dashboardPhaseLabel,
                tone: model.runtimeSnapshot.overallTone
            )
        }
    }

    private var codexHero: some View {
        StatusCard(
            title: "Codex",
            subtitle: projectSubtitle,
            systemImage: "sparkles.rectangle.stack.fill",
            tone: codexTone
        ) {
            HStack(alignment: .bottom, spacing: 24) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(agentStatus)
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                    Text(codexSourceDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 5) {
                    Text(sevenDayQuota)
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                    Text("7 天额度剩余")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            HStack {
                Label("固定首页", systemImage: "house.fill")
                Spacer()
                Text(quotaFreshnessDescription)
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
        }
    }

    private var voiceCard: some View {
        StatusCard(
            title: "语音输入",
            subtitle: "基础能力，始终保留",
            systemImage: "waveform",
            tone: model.hasConfiguredASR ? .neutral : .warning
        ) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.hasConfiguredASR ? "语音供应方已配置" : "尚未发现配置")
                        .font(.title3.weight(.semibold))
                    Text(asrDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                PhasePill(
                    text: model.configurationSummary.autoEnterEnabled ? "识别后自动发送" : "仅粘贴，不自动发送",
                    tone: .neutral
                )
            }
            .frame(
                maxWidth: .infinity,
                minHeight: compactCardContentMinimumHeight,
                alignment: .topLeading
            )
        }
    }

    private var backgroundCard: some View {
        StatusCard(
            title: "Mac 后台",
            subtitle: "Bridge · HUD · Paste",
            systemImage: "macwindow.badge.plus",
            tone: model.runtimeSnapshot.overallTone
        ) {
            VStack(spacing: 8) {
                compactStatus(model.runtimeSnapshot.bridge)
                compactStatus(model.runtimeSnapshot.hud)
                compactStatus(model.runtimeSnapshot.paste)
            }
            .frame(
                maxWidth: .infinity,
                minHeight: compactCardContentMinimumHeight,
                alignment: .topLeading
            )
        }
    }

    private var quickActions: some View {
        HStack(spacing: 12) {
            Button {
                onSelectSection(.connection)
            } label: {
                Label("查看后台与权限", systemImage: "checklist")
            }
            .buttonStyle(.borderedProminent)

            Button {
                onSelectSection(.deviceInterface)
            } label: {
                Label("预览设备首页", systemImage: "display")
            }
            .buttonStyle(.bordered)

            Spacer()
        }
    }

    private func compactStatus(_ component: ComponentHealth) -> some View {
        HStack {
            Circle()
                .fill(component.phase.tone.color)
                .frame(width: 7, height: 7)
            Text(component.kind.title)
            Spacer()
            Text(component.phase.label)
                .foregroundStyle(component.phase.tone.color)
        }
        .font(.caption.weight(.medium))
    }

    private var projectSubtitle: String {
        if let project = model.bridgeSnapshot.state?.codexState?.project, !project.isEmpty {
            return project
        }
        if let project = model.configurationSummary.projectName {
            return project
        }
        return "项目名称未显示"
    }

    private var agentStatus: String {
        guard let status = model.bridgeSnapshot.state?.codexState?.status, !status.isEmpty else {
            return "等待连接"
        }
        return status.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private var sevenDayQuota: String {
        guard let remaining = model.bridgeSnapshot.state?.codexState?.quota7DRemaining else {
            return "—"
        }
        return "\(Int(remaining.rounded()))%"
    }

    private var asrDescription: String {
        if let native = model.configuration.asr {
            return "当前供应方：\(native.provider.title)"
        }
        if let provider = model.configurationSummary.asrProvider {
            return "当前供应方：\(provider)"
        }
        return model.configurationSummary.asrConfigurationDetected
            ? "已读取摘要，尚未在控制中心验证可用性"
            : "可在“语音与发送”中完成原生配置"
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: "早上好"
        case 12..<18: "下午好"
        default: "晚上好"
        }
    }

    private var dashboardPhaseLabel: String {
        if model.runtimeSnapshot.checkedAt == .distantPast { return "正在检查" }
        return model.runtimeSnapshot.overallTone == .healthy ? "全部就绪" : "需要留意"
    }

    private var codexTone: HealthTone {
        guard model.bridgeSnapshot.isHealthy else { return .warning }
        return model.bridgeSnapshot.state?.codexState?.quotaStale == true ? .warning : .healthy
    }

    private var codexSourceDescription: String {
        guard model.bridgeSnapshot.isHealthy else { return "等待本机连接服务" }
        return model.bridgeSnapshot.state?.codexState == nil ? "Codex 状态暂时不可用" : "本机 Codex 状态来源可用"
    }

    private var quotaFreshnessDescription: String {
        if model.bridgeSnapshot.state?.codexState?.quotaStale == true {
            return "额度缓存可能已过期"
        }
        return "仅显示 Bridge 当前提供的 7 天窗口"
    }
}
