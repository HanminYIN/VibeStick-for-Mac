import Combine
import Foundation

// M4-5G extends the explicit M4-5F state machine with a redacted ASR conflict
// choice. Creating
// this flow is inert: the operation builder is not called until startDiscovery()
// is invoked by an explicit UI action. The published state contains only
// source labels, redacted categories, blockers, managed targets, and receipt
// booleans; it never contains ASR parameters, commands, endpoints, or secrets.

protocol M4LegacyMigrationUIOperating: Sendable {
    func discover() async throws -> M4LegacyMigrationPreview
    func migrate(
        preview: M4LegacyMigrationPreview,
        confirmation: M4ExplicitLegacyMigrationConfirmation
    ) async throws -> M4LegacyMigrationReceiptSummary
}

extension M4ExplicitLegacyMigrationEntry: M4LegacyMigrationUIOperating {}

protocol M4LegacyMigrationUIOperationBuilding: Sendable {
    func makeOperation() throws -> any M4LegacyMigrationUIOperating
}

struct M4ProductionLegacyMigrationUIOperationBuilder:
    M4LegacyMigrationUIOperationBuilding,
    Sendable
{
    private let runtimeFacts: any M4LegacyRuntimeFactsReading

    init(runtimeFacts: any M4LegacyRuntimeFactsReading) {
        self.runtimeFacts = runtimeFacts
    }

    func makeOperation() throws -> any M4LegacyMigrationUIOperating {
        try M4ExplicitLegacyMigrationEntry.production(runtimeFacts: runtimeFacts)
    }
}

struct M4ExplicitActionLegacyRuntimeFactsReader: M4LegacyRuntimeFactsReading, Sendable {
    private let reader: @Sendable () async throws -> M4LegacyRuntimeFacts

    init(reader: @escaping @Sendable () async throws -> M4LegacyRuntimeFacts) {
        self.reader = reader
    }

    func readRuntimeFacts() async throws -> M4LegacyRuntimeFacts {
        try await reader()
    }
}

extension M4LegacyRuntimeFacts {
    static func appSnapshot(_ runtime: RuntimeSnapshot) -> Self {
        let components = [runtime.bridge, runtime.hud, runtime.paste]
        let installed = components.contains { component in
            component.isInstalled
                || component.ownership == .externalProcess
                || component.ownership == .conflictingProcess
        }
        let unknownOwner = components.contains { component in
            return component.ownership == .externalProcess
                || component.ownership == .conflictingProcess
        }

        return Self(
            runtimeComponentsInstalled: installed,
            runtimeOwnershipIsUnknown: unknownOwner,
            activeVoiceWorkExists: runtime.isRecordingActive,
            pasteIdentity: runtime.paste.isInstalled ? "com.vibestick.paste" : nil,
            accessibilityPermissionGranted: runtime.paste.isInstalled
                && runtime.paste.phase == .healthy,
            soundEnabled: nil
        )
    }
}

struct M4LegacyMigrationUIReview: Equatable, Sendable {
    let categories: [M4LegacyConfigurationCategory]
    let asrConfigurationSources: [M4ASRConfigurationSource]
    let legacyFileExists: Bool
    let legacyFilePermissionsArePrivate: Bool
    let blockers: [M4LegacyMigrationBlocker]
    let requiredTargets: [M4MigrationOwnedTarget]
    let preservesLegacyFiles: Bool
    let mayDeleteLegacyFiles: Bool
    let mayRestartRuntime: Bool

    var canOfferMigration: Bool {
        !categories.isEmpty && blockers.isEmpty
    }

    init(preview: M4LegacyMigrationPreview) {
        categories = preview.plan.categories
        asrConfigurationSources = preview.asrConfigurationConflict?.availableSources
            .sorted { $0.rawValue < $1.rawValue } ?? []
        legacyFileExists = preview.discovery.legacyFileExists
        legacyFilePermissionsArePrivate = preview.discovery.legacyFilePermissionsArePrivate
        blockers = preview.plan.blockers
        requiredTargets = M4MigrationOwnedTargetPolicy.requiredTargets(
            for: preview.discovery.detectedCategories
        ).sorted { $0.rawValue < $1.rawValue }
        preservesLegacyFiles = preview.plan.preservesLegacyFiles
        mayDeleteLegacyFiles = preview.plan.mayDeleteLegacyFiles
        mayRestartRuntime = preview.plan.mayRestartRuntime
    }
}

struct M4LegacyMigrationUISelection: Equatable, Sendable {
    var categories: Set<M4LegacyConfigurationCategory> = []
    var ownedTargets: Set<M4MigrationOwnedTarget> = []
    var asrConfigurationSource: M4ASRConfigurationSource?

    func exactlyConfirms(_ review: M4LegacyMigrationUIReview) -> Bool {
        let sourceIsExact = review.asrConfigurationSources.isEmpty
            ? asrConfigurationSource == nil
            : asrConfigurationSource.map(review.asrConfigurationSources.contains) == true
        return categories == Set(review.categories)
            && ownedTargets == Set(review.requiredTargets)
            && sourceIsExact
            && review.canOfferMigration
    }
}

struct M4LegacyMigrationUIFinalConfirmationSummary: Equatable, Sendable {
    let asrConfigurationSource: M4ASRConfigurationSource?
    let categories: [M4LegacyConfigurationCategory]
    let ownedTargets: [M4MigrationOwnedTarget]

    init?(
        review: M4LegacyMigrationUIReview,
        selection: M4LegacyMigrationUISelection
    ) {
        guard selection.exactlyConfirms(review) else { return nil }
        asrConfigurationSource = selection.asrConfigurationSource
        categories = review.categories
        ownedTargets = review.requiredTargets
    }

    var redactedMessage: String {
        let sourceTitle = asrConfigurationSource.map(
            M4LegacyMigrationUICopy.asrConfigurationSourceTitle
        ) ?? "无需选择（未发现来源冲突）"
        let categoryLines = categories.map {
            "• \(M4LegacyMigrationUICopy.categoryTitle($0))"
        }
        let targetLines = ownedTargets.map {
            "• \(M4LegacyMigrationUICopy.ownedTargetTitle($0))"
        }

        return ([
            "ASR 配置来源：\(sourceTitle)",
            "迁移类别（\(categories.count) 项）：",
        ] + categoryLines + [
            "受管目标（\(ownedTargets.count) 项）：",
        ] + targetLines + [
            "将再次检查旧版状态，再写入上述受管配置。旧版文件和旧钥匙串项目会保留；不会启动或重启 Bridge、HUD、Paste。",
        ]).joined(separator: "\n")
    }
}

enum M4LegacyMigrationUICopy {
    static func categoryTitle(_ category: M4LegacyConfigurationCategory) -> String {
        switch category {
        case .runtimeComponents: "现有 Bridge、HUD 与 Paste 组件身份"
        case .bridgeCredential: "Bridge 凭据引用"
        case .asrCredential: "语音识别凭据引用"
        case .asrConfiguration: "语音识别配置"
        case .agentProvider: "代理提供方"
        case .projectPresentation: "项目显示设置"
        case .voiceDelivery: "语音发送设置"
        case .soundPreference: "声音偏好"
        case .accessibilityPermission: "辅助功能权限状态"
        }
    }

    static func ownedTargetTitle(_ target: M4MigrationOwnedTarget) -> String {
        switch target {
        case .privateRollbackSnapshot: "私有回退快照"
        case .versionedKeychainAccounts: "新的版本化钥匙串账户"
        case .managedConfigurationFiles: "受管非密钥配置文件"
        case .existingPasteIdentity: "保留现有 Paste 身份"
        }
    }

    static func asrConfigurationSourceTitle(_ source: M4ASRConfigurationSource) -> String {
        switch source {
        case .currentApp: "当前 App 配置"
        case .legacyEnvironment: "旧 .env 配置"
        }
    }
}

enum M4LegacyMigrationUIFailure: String, Equatable, Sendable {
    case discoveryFailed
    case migrationFailed
}

enum M4LegacyMigrationUIState: Equatable, Sendable {
    case idle
    case discovering
    case reviewing(
        review: M4LegacyMigrationUIReview,
        selection: M4LegacyMigrationUISelection
    )
    case awaitingFinalConfirmation(
        review: M4LegacyMigrationUIReview,
        selection: M4LegacyMigrationUISelection
    )
    case migrating(review: M4LegacyMigrationUIReview)
    case completed(receipt: M4LegacyMigrationReceiptSummary)
    case failed(M4LegacyMigrationUIFailure)
}

@MainActor
final class M4LegacyMigrationUIFlow: ObservableObject {
    @Published private(set) var state: M4LegacyMigrationUIState = .idle

    private let builder: any M4LegacyMigrationUIOperationBuilding
    private var operation: (any M4LegacyMigrationUIOperating)?
    private var preview: M4LegacyMigrationPreview?
    private var migrationCompletionHandler: (@MainActor @Sendable () async -> Void)?

    init(builder: any M4LegacyMigrationUIOperationBuilding) {
        self.builder = builder
    }

    func setMigrationCompletionHandler(
        _ handler: @escaping @MainActor @Sendable () async -> Void
    ) {
        migrationCompletionHandler = handler
    }

    var isAwaitingFinalConfirmation: Bool {
        if case .awaitingFinalConfirmation = state { return true }
        return false
    }

    var finalConfirmationSummary: M4LegacyMigrationUIFinalConfirmationSummary? {
        guard case let .awaitingFinalConfirmation(review, selection) = state else {
            return nil
        }
        return M4LegacyMigrationUIFinalConfirmationSummary(
            review: review,
            selection: selection
        )
    }

    func startDiscovery() async {
        switch state {
        case .idle, .completed, .failed:
            break
        case .discovering, .reviewing, .awaitingFinalConfirmation, .migrating:
            return
        }
        operation = nil
        preview = nil
        state = .discovering

        do {
            let created = try builder.makeOperation()
            let discovered = try await created.discover()
            operation = created
            preview = discovered
            state = .reviewing(
                review: M4LegacyMigrationUIReview(preview: discovered),
                selection: M4LegacyMigrationUISelection()
            )
        } catch {
            operation = nil
            preview = nil
            state = .failed(.discoveryFailed)
        }
    }

    func setCategory(_ category: M4LegacyConfigurationCategory, selected: Bool) {
        guard case let .reviewing(review, current) = state,
              review.categories.contains(category) else { return }
        var selection = current
        if selected {
            selection.categories.insert(category)
        } else {
            selection.categories.remove(category)
        }
        state = .reviewing(review: review, selection: selection)
    }

    func setOwnedTarget(_ target: M4MigrationOwnedTarget, selected: Bool) {
        guard case let .reviewing(review, current) = state,
              review.requiredTargets.contains(target) else { return }
        var selection = current
        if selected {
            selection.ownedTargets.insert(target)
        } else {
            selection.ownedTargets.remove(target)
        }
        state = .reviewing(review: review, selection: selection)
    }

    func setASRConfigurationSource(_ source: M4ASRConfigurationSource) {
        guard case let .reviewing(review, current) = state,
              review.asrConfigurationSources.contains(source) else { return }
        var selection = current
        selection.asrConfigurationSource = source
        state = .reviewing(review: review, selection: selection)
    }

    @discardableResult
    func requestFinalConfirmation() -> Bool {
        guard case let .reviewing(review, selection) = state,
              selection.exactlyConfirms(review) else { return false }
        state = .awaitingFinalConfirmation(review: review, selection: selection)
        return true
    }

    func cancelFinalConfirmation() {
        guard case let .awaitingFinalConfirmation(review, selection) = state else { return }
        state = .reviewing(review: review, selection: selection)
    }

    func executeMigration() async {
        guard case let .awaitingFinalConfirmation(review, selection) = state,
              selection.exactlyConfirms(review),
              let operation,
              let preview else { return }
        state = .migrating(review: review)

        do {
            let receipt = try await operation.migrate(
                preview: preview,
                confirmation: M4ExplicitLegacyMigrationConfirmation(
                    confirmedCategories: selection.categories,
                    ownedTargets: selection.ownedTargets,
                    asrConfigurationSource: selection.asrConfigurationSource
                )
            )
            self.operation = nil
            self.preview = nil
            state = .completed(receipt: receipt)
            await migrationCompletionHandler?()
        } catch {
            self.operation = nil
            self.preview = nil
            state = .failed(.migrationFailed)
        }
    }

    func reset() {
        guard !isBusy else { return }
        operation = nil
        preview = nil
        state = .idle
    }

    private var isBusy: Bool {
        switch state {
        case .discovering, .migrating:
            true
        case .idle, .reviewing, .awaitingFinalConfirmation, .completed, .failed:
            false
        }
    }
}
