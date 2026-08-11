import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selection: AppSection? = .overview

    var body: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.systemImage)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 260)
            .safeAreaInset(edge: .bottom) {
                sidebarFooter
            }
        } detail: {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .tint(VibeStickStyle.accent)
        .onAppear {
            model.markWindowVisibleForSmokeProbe()
        }
        .alert(item: $model.presentedMessage) { message in
            Alert(
                title: Text(message.title),
                message: Text(message.message),
                dismissButton: .default(Text("好"))
            )
        }
    }

    @ViewBuilder
    private var content: some View {
        switch selection ?? .overview {
        case .overview:
            DashboardView(onSelectSection: { selection = $0 })
        case .deviceInterface:
            DeviceInterfaceView()
        case .voice:
            VoiceAndSendView()
        case .buttons:
            ButtonAndReminderView()
        case .connection:
            ConnectionAndRuntimeView()
        case .updates:
            UpdatesAndRecoveryView()
        case .advanced:
            AdvancedSettingsView()
        }
    }

    private var sidebarFooter: some View {
        HStack(spacing: 10) {
            Image(systemName: sidebarStatusSymbol)
                .foregroundStyle(model.runtimeSnapshot.overallTone.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(sidebarStatusLabel)
                    .font(.caption.weight(.medium))
                Text("关闭窗口不会停止服务")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(.bar)
    }

    private var sidebarStatusSymbol: String {
        if model.runtimeSnapshot.checkedAt == .distantPast { return "clock.fill" }
        return model.runtimeSnapshot.overallTone == .healthy
            ? "checkmark.circle.fill"
            : "exclamationmark.circle.fill"
    }

    private var sidebarStatusLabel: String {
        if model.runtimeSnapshot.checkedAt == .distantPast { return "正在检查后台" }
        return model.runtimeSnapshot.overallTone == .healthy ? "后台运行正常" : "有一项需要留意"
    }
}
