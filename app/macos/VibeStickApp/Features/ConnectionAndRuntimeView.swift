import SwiftUI

struct ConnectionAndRuntimeView: View {
    @EnvironmentObject private var model: AppModel
    @State private var isConfirmingStop = false
    @State private var isConfirmingRestart = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("连接与后台")
                            .font(.largeTitle.weight(.bold))
                        Text("管理现有稳定服务，不会在后台重装或替换它们。")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    PhasePill(text: overallLabel, tone: model.runtimeSnapshot.overallTone)
                }

                StatusCard(
                    title: "当前运行状态",
                    subtitle: checkedAtDescription,
                    systemImage: "checklist.checked",
                    tone: model.runtimeSnapshot.overallTone
                ) {
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
                }

                if model.runtimeSnapshot.paste.phase == .permissionMissing {
                    permissionCard
                }

                serviceControls
            }
            .padding(30)
            .frame(maxWidth: 920, alignment: .leading)
        }
        .navigationTitle("连接与后台")
        .toolbar {
            ToolbarItem {
                Button {
                    model.requestRefresh(forcePermissionCheck: true)
                } label: {
                    Label("重新检查", systemImage: "arrow.clockwise")
                }
                .disabled(model.isRefreshing)
            }
        }
    }

    private var permissionCard: some View {
        StatusCard(
            title: "还差一个辅助功能权限",
            subtitle: "它只用于把识别出的文字输入到当前应用",
            systemImage: "hand.raised.fill",
            tone: .warning
        ) {
            Text("系统设置打开后，请为“VibeStick Paste”开启辅助功能。控制中心不会申请或冒充这项权限。")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack {
                Button("打开辅助功能设置") {
                    SystemSettingsOpener.openAccessibility()
                }
                .buttonStyle(.borderedProminent)

                Button("我已开启，重新检查") {
                    model.requestRefresh(forcePermissionCheck: true)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var serviceControls: some View {
        StatusCard(
            title: "后台控制",
            subtitle: "这些操作只控制已安装的 Bridge 与 HUD",
            systemImage: "power",
            tone: .neutral
        ) {
            HStack(spacing: 10) {
                Button {
                    model.performServiceAction(.start)
                } label: {
                    Label("启动", systemImage: "play.fill")
                }

                Button {
                    isConfirmingRestart = true
                } label: {
                    Label("重新启动", systemImage: "arrow.clockwise")
                }

                Button(role: .destructive) {
                    isConfirmingStop = true
                } label: {
                    Label("停止", systemImage: "stop.fill")
                }

                Spacer()
                if model.serviceActionInProgress {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在处理…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.bordered)
            .disabled(serviceControlsDisabled)

            if model.runtimeSnapshot.isRecordingActive {
                Label("正在录音或识别，完成后才能停止或重新启动后台。", systemImage: "waveform.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if model.runtimeSnapshot.bridge.ownership == .conflictingProcess {
                Label("端口 8765 被未知程序占用。为避免冲突，后台控制已停用。", systemImage: "exclamationmark.shield.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if model.runtimeSnapshot.bridge.ownership == .externalProcess {
                Label("检测到由其他方式运行的 Bridge。为避免重复进程，控制中心保持只读。", systemImage: "shield.lefthalf.filled")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Text("退出 VibeStick for Mac 不会停止后台；只有点击“停止”才会停用现有服务。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .confirmationDialog(
            "停止设备后台服务？",
            isPresented: $isConfirmingStop,
            titleVisibility: .visible
        ) {
            Button("停止 Bridge 与 HUD", role: .destructive) {
                model.performServiceAction(.stop)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("语音输入和设备状态会暂停；稍后可在这里重新启动。现有配置不会被删除。")
        }
        .confirmationDialog(
            "重新启动设备后台服务？",
            isPresented: $isConfirmingRestart,
            titleVisibility: .visible
        ) {
            Button("重新启动 Bridge 与 HUD") {
                model.performServiceAction(.restart)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("连接会短暂中断。现有配置和文字输入权限不会被修改。")
        }
    }

    private var serviceControlsDisabled: Bool {
        model.serviceActionInProgress
            || model.runtimeSnapshot.isRecordingActive
            || model.runtimeSnapshot.checkedAt == .distantPast
            || model.runtimeSnapshot.bridge.ownership == .externalProcess
            || model.runtimeSnapshot.bridge.ownership == .conflictingProcess
    }

    private var overallLabel: String {
        model.runtimeSnapshot.overallTone == .healthy ? "全部正常" : "有项目需要处理"
    }

    private var checkedAtDescription: String {
        guard model.runtimeSnapshot.checkedAt != .distantPast else { return "正在检查" }
        return "上次检查：\(model.runtimeSnapshot.checkedAt.formatted(date: .omitted, time: .standard))"
    }
}
