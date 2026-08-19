import SwiftUI

enum VibeStickStyle {
    static let accent = Color(red: 0.20, green: 0.49, blue: 0.98)
    static let cardCornerRadius: CGFloat = 18
    static let cardPadding: CGFloat = 20
}

struct StatusCard<Content: View>: View {
    let title: String
    let subtitle: String?
    let systemImage: String
    let tone: HealthTone
    private let content: Content

    init(
        title: String,
        subtitle: String? = nil,
        systemImage: String,
        tone: HealthTone = .neutral,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.tone = tone
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: systemImage)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(tone.color)
                    .frame(width: 34, height: 34)
                    .background(tone.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                    if let subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            content
        }
        .padding(VibeStickStyle.cardPadding)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: VibeStickStyle.cardCornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: VibeStickStyle.cardCornerRadius)
                .stroke(.separator.opacity(0.45), lineWidth: 1)
        }
    }
}

struct ServiceStatusRow: View {
    let component: ComponentHealth
    let showTechnicalDetails: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: component.kind.systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(component.phase.tone.color)
                .frame(width: 34, height: 34)
                .background(component.phase.tone.color.opacity(0.11), in: RoundedRectangle(cornerRadius: 9))

            VStack(alignment: .leading, spacing: 3) {
                Text(component.kind.title)
                    .font(.body.weight(.medium))
                Text(component.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if showTechnicalDetails {
                    Text(component.kind.technicalName)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 12)
            Label(component.phase.label, systemImage: statusSymbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(component.phase.tone.color)
                .labelStyle(.titleAndIcon)
        }
        .padding(.vertical, 6)
    }

    private var statusSymbol: String {
        switch component.phase {
        case .healthy: "checkmark.circle.fill"
        case .permissionMissing, .versionMismatch, .portConflict, .needsRepair, .runningNotReady: "exclamationmark.triangle.fill"
        case .starting, .unknown: "clock.fill"
        case .notInstalled, .stopped: "minus.circle.fill"
        }
    }
}

struct PhasePill: View {
    let text: String
    let tone: HealthTone

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(tone.color)
                .frame(width: 7, height: 7)
            Text(text)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(tone.color)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(tone.color.opacity(0.11), in: Capsule())
    }
}

struct ComingSoonBadge: View {
    let milestone: String

    var body: some View {
        Text("将在 \(milestone) 开放")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.quaternary, in: Capsule())
    }
}

struct CurrentMilestoneBadge: View {
    let milestone: String

    var body: some View {
        Text("\(milestone) · 当前阶段")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.blue)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.blue.opacity(0.11), in: Capsule())
    }
}
