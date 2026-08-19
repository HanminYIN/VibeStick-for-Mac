import Foundation
import Testing

@MainActor
struct M4MigrationUIFlowTests {
    @Test
    func initializationIsInertUntilExplicitDiscovery() async {
        let operation = M4FFictionalOperation(preview: M4FFixtures.preview())
        let builder = M4FFictionalBuilder(operation: operation)
        let flow = M4LegacyMigrationUIFlow(builder: builder)

        #expect(flow.state == .idle)
        #expect(builder.creationCount == 0)
        #expect(await operation.discoveryCount == 0)
        #expect(await operation.migrationCount == 0)
    }

    @Test
    func runtimeFactMappingFailsClosedForExternalRuntimeWithoutProbingAccessibility() {
        let snapshot = RuntimeSnapshot(
            bridge: ComponentHealth(
                kind: .bridge,
                phase: .healthy,
                detail: "fictional external bridge",
                isInstalled: false,
                ownership: .externalProcess
            ),
            hud: ComponentHealth(
                kind: .hud,
                phase: .notInstalled,
                detail: "fictional missing hud",
                isInstalled: false,
                ownership: .none
            ),
            paste: ComponentHealth(
                kind: .paste,
                phase: .unknown,
                detail: "fictional unprobed paste",
                isInstalled: true,
                ownership: .legacyLaunchAgent
            ),
            isRecordingActive: false,
            checkedAt: Date(timeIntervalSince1970: 1)
        )

        let facts = M4LegacyRuntimeFacts.appSnapshot(snapshot)

        #expect(facts.runtimeComponentsInstalled)
        #expect(facts.runtimeOwnershipIsUnknown)
        #expect(facts.pasteIdentity == "com.vibestick.paste")
        #expect(!facts.accessibilityPermissionGranted)
        #expect(facts.soundEnabled == nil)
    }

    @Test
    func explicitDiscoveryBuildsOnceAndPublishesOnlyRedactedReview() async {
        let operation = M4FFictionalOperation(preview: M4FFixtures.preview())
        let builder = M4FFictionalBuilder(operation: operation)
        let flow = M4LegacyMigrationUIFlow(builder: builder)

        await flow.startDiscovery()

        guard case let .reviewing(review, selection) = flow.state else {
            Issue.record("Expected reviewing state")
            return
        }
        let reflected = String(reflecting: flow.state)
        #expect(builder.creationCount == 1)
        #expect(await operation.discoveryCount == 1)
        #expect(await operation.migrationCount == 0)
        #expect(review.categories == M4FFixtures.preview().plan.categories)
        #expect(selection.categories.isEmpty)
        #expect(selection.ownedTargets.isEmpty)
        #expect(!reflected.contains(M4FFixtures.secretText))
        #expect(!reflected.contains(M4FFixtures.privatePath))
    }

    @Test
    func incompleteOrExpandedSelectionCannotReachFinalConfirmation() async {
        let preview = M4FFixtures.preview(categories: [.bridgeCredential])
        let operation = M4FFictionalOperation(preview: preview)
        let flow = M4LegacyMigrationUIFlow(
            builder: M4FFictionalBuilder(operation: operation)
        )
        await flow.startDiscovery()

        flow.setCategory(.bridgeCredential, selected: true)
        flow.setOwnedTarget(.privateRollbackSnapshot, selected: true)
        #expect(!flow.requestFinalConfirmation())

        flow.setOwnedTarget(.managedConfigurationFiles, selected: true)
        #expect(!flow.requestFinalConfirmation())
        #expect(await operation.migrationCount == 0)

        guard case let .reviewing(_, selection) = flow.state else {
            Issue.record("Expected reviewing state")
            return
        }
        #expect(!selection.ownedTargets.contains(.managedConfigurationFiles))
    }

    @Test
    func conflictingASRRequiresOneExplicitRedactedSourceChoice() async {
        let preview = M4FFixtures.preview(asrConflict: true)
        let operation = M4FFictionalOperation(preview: preview)
        let flow = M4LegacyMigrationUIFlow(
            builder: M4FFictionalBuilder(operation: operation)
        )
        await flow.startDiscovery()

        guard case let .reviewing(review, selection) = flow.state else {
            Issue.record("Expected reviewing state")
            return
        }
        #expect(review.asrConfigurationSources == [.currentApp, .legacyEnvironment])
        #expect(selection.asrConfigurationSource == nil)
        let reflected = String(reflecting: flow.state)
        #expect(!reflected.contains(M4FFixtures.secretText))
        #expect(!reflected.contains(M4FFixtures.privatePath))

        confirmEveryDisplayedItem(in: flow)
        #expect(!flow.requestFinalConfirmation())
        flow.setASRConfigurationSource(.currentApp)
        #expect(flow.requestFinalConfirmation())
        await flow.executeMigration()

        #expect(await operation.lastConfirmation?.asrConfigurationSource == .currentApp)
        #expect(await operation.migrationCount == 1)
    }

    @Test
    func exactSelectionCanBeCancelledWithoutCallingMigration() async {
        let operation = M4FFictionalOperation(preview: M4FFixtures.preview())
        let flow = M4LegacyMigrationUIFlow(
            builder: M4FFictionalBuilder(operation: operation)
        )
        await flow.startDiscovery()
        confirmEveryDisplayedItem(in: flow)

        #expect(flow.requestFinalConfirmation())
        #expect(flow.isAwaitingFinalConfirmation)
        #expect(flow.finalConfirmationSummary != nil)
        flow.cancelFinalConfirmation()

        #expect(!flow.isAwaitingFinalConfirmation)
        #expect(flow.finalConfirmationSummary == nil)
        #expect(await operation.migrationCount == 0)
        guard case .reviewing = flow.state else {
            Issue.record("Expected review to remain available after cancellation")
            return
        }
    }

    @Test
    func finalConfirmationListsCurrentAppSevenCategoriesAndFourTargetsRedacted() async {
        let categories: Set<M4LegacyConfigurationCategory> = [
            .agentProvider,
            .asrConfiguration,
            .asrCredential,
            .bridgeCredential,
            .projectPresentation,
            .runtimeComponents,
            .voiceDelivery,
        ]
        let preview = M4FFixtures.preview(categories: categories, asrConflict: true)
        let operation = M4FFictionalOperation(preview: preview)
        let flow = M4LegacyMigrationUIFlow(
            builder: M4FFictionalBuilder(operation: operation)
        )
        await flow.startDiscovery()
        confirmEveryDisplayedItem(in: flow)
        flow.setASRConfigurationSource(.currentApp)

        #expect(flow.requestFinalConfirmation())
        guard let summary = flow.finalConfirmationSummary else {
            Issue.record("Expected a redacted final confirmation summary")
            return
        }

        #expect(summary.asrConfigurationSource == .currentApp)
        #expect(summary.categories == preview.plan.categories)
        #expect(summary.categories.count == 7)
        #expect(summary.ownedTargets.count == 4)

        let message = summary.redactedMessage
        #expect(message.contains("ASR 配置来源：当前 App 配置"))
        #expect(message.contains("迁移类别（7 项）："))
        #expect(message.contains("受管目标（4 项）："))
        for category in summary.categories {
            #expect(message.contains(M4LegacyMigrationUICopy.categoryTitle(category)))
        }
        for target in summary.ownedTargets {
            #expect(message.contains(M4LegacyMigrationUICopy.ownedTargetTitle(target)))
        }
        #expect(!message.contains(M4FFixtures.secretText))
        #expect(!message.contains(M4FFixtures.privatePath))
        #expect(await operation.migrationCount == 0)
    }

    @Test
    func finalConfirmationPassesExactScopeAndReportsNoRuntimeActivation() async {
        let preview = M4FFixtures.preview()
        let receipt = M4FFixtures.receipt(categories: preview.plan.categories)
        let operation = M4FFictionalOperation(preview: preview, receipt: receipt)
        let flow = M4LegacyMigrationUIFlow(
            builder: M4FFictionalBuilder(operation: operation)
        )
        await flow.startDiscovery()
        confirmEveryDisplayedItem(in: flow)
        #expect(flow.requestFinalConfirmation())

        await flow.executeMigration()

        guard case let .completed(actual) = flow.state else {
            Issue.record("Expected completed state")
            return
        }
        let confirmation = await operation.lastConfirmation
        #expect(await operation.migrationCount == 1)
        #expect(confirmation?.confirmedCategories == preview.discovery.detectedCategories)
        #expect(confirmation?.ownedTargets == M4MigrationOwnedTargetPolicy.requiredTargets(
            for: preview.discovery.detectedCategories
        ))
        #expect(actual.configurationCommitted)
        #expect(actual.legacyFallbackRetained)
        #expect(!actual.legacyItemsDeleted)
        #expect(!actual.runtimeRestarted)
        #expect(!actual.runtimeActivationAuthorized)
        #expect(actual.runtimeActivationRequired)
    }

    @Test
    func completedMigrationInvokesOnlyTheInjectedManagedStatusRefresh() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VibeStick-M4-5H-AppModel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("fictional-managed-runtime.json")
        let references: [M4VersionedCredentialReference] = [
            .managed(.bridgeToken),
            .managed(.asrAPIKey),
        ]
        let configuration = M4ManagedRuntimeConfiguration(
            schemaVersion: M4ManagedRuntimeConfiguration.currentSchemaVersion,
            credentialReferences: references,
            asr: M4ManagedASRConfiguration(
                provider: "openai-compatible",
                baseURL: "https://fictional.invalid/v1/audio/transcriptions",
                model: "fictional-m4-5h-model",
                language: "zh",
                localCommand: ""
            ),
            agentProvider: "auto",
            projectPresentation: nil,
            voiceDelivery: M4ManagedVoiceDelivery(sendMode: "confirm"),
            soundEnabled: true
        )
        try JSONEncoder().encode(configuration).write(to: file)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: file.path
        )
        let checker = M4HMockManagedCredentialPresenceChecker(present: Set(references))
        let statusInspector = M4ManagedRuntimeStatusInspector(
            configurationReader: M4FoundationManagedRuntimeConfigurationReader(fileURL: file),
            credentialPresenceChecker: checker
        )
        let preview = M4FFixtures.preview()
        let operation = M4FFictionalOperation(preview: preview)
        let flow = M4LegacyMigrationUIFlow(
            builder: M4FFictionalBuilder(operation: operation)
        )
        let refreshRecorder = M4HManagedStatusRefreshRecorder(inspector: statusInspector)
        flow.setMigrationCompletionHandler {
            await refreshRecorder.refresh()
        }

        let initialSummary = await refreshRecorder.summary
        #expect(initialSummary == .empty)
        await flow.startDiscovery()
        confirmEveryDisplayedItem(in: flow)
        #expect(flow.requestFinalConfirmation())

        await flow.executeMigration()

        let refreshed = await refreshRecorder.summary
        let refreshCount = await refreshRecorder.refreshCount
        let checkedCount = await checker.checkedReferences.count
        #expect(refreshed.configurationState == .validated)
        #expect(refreshed.bridgeCredentialState == .stored)
        #expect(refreshed.asrCredentialState == .stored)
        #expect(refreshed.hasStoredReferencedCredentials)
        #expect(refreshCount == 1)
        #expect(checkedCount == 2)
        #expect(await operation.migrationCount == 1)
    }

    @Test
    func blockersRemainVisibleButMigrationCannotBeArmed() async {
        let preview = M4FFixtures.preview(
            categories: [.runtimeComponents, .bridgeCredential],
            unknownOwner: true,
            activeVoice: true
        )
        let operation = M4FFictionalOperation(preview: preview)
        let flow = M4LegacyMigrationUIFlow(
            builder: M4FFictionalBuilder(operation: operation)
        )
        await flow.startDiscovery()

        guard case let .reviewing(review, _) = flow.state else {
            Issue.record("Expected reviewing state")
            return
        }
        #expect(review.blockers == [.unknownRuntimeOwner, .activeVoiceWork])
        #expect(!review.canOfferMigration)
        confirmEveryDisplayedItem(in: flow)
        #expect(!flow.requestFinalConfirmation())
        #expect(await operation.migrationCount == 0)
    }

    @Test
    func discoveryFailureDoesNotPublishUnderlyingSensitiveError() async {
        let operation = M4FFictionalOperation(
            preview: M4FFixtures.preview(),
            discoveryFails: true
        )
        let flow = M4LegacyMigrationUIFlow(
            builder: M4FFictionalBuilder(operation: operation)
        )

        await flow.startDiscovery()

        #expect(flow.state == .failed(.discoveryFailed))
        let reflected = String(reflecting: flow.state)
        #expect(!reflected.contains(M4FFixtures.secretText))
        #expect(!reflected.contains(M4FFixtures.privatePath))
    }

    @Test
    func migrationFailureIsRedactedAndRequiresFreshDiscovery() async {
        let operation = M4FFictionalOperation(
            preview: M4FFixtures.preview(),
            migrationFails: true
        )
        let flow = M4LegacyMigrationUIFlow(
            builder: M4FFictionalBuilder(operation: operation)
        )
        await flow.startDiscovery()
        confirmEveryDisplayedItem(in: flow)
        #expect(flow.requestFinalConfirmation())

        await flow.executeMigration()

        #expect(flow.state == .failed(.migrationFailed))
        let reflected = String(reflecting: flow.state)
        #expect(!reflected.contains(M4FFixtures.secretText))
        #expect(!reflected.contains(M4FFixtures.privatePath))
        flow.reset()
        #expect(flow.state == .idle)
    }

    @Test
    func resetAndRetryCreatesAFreshExplicitDiscovery() async {
        let operation = M4FFictionalOperation(preview: M4FFixtures.preview())
        let builder = M4FFictionalBuilder(operation: operation)
        let flow = M4LegacyMigrationUIFlow(builder: builder)

        await flow.startDiscovery()
        flow.reset()
        await flow.startDiscovery()

        #expect(builder.creationCount == 2)
        #expect(await operation.discoveryCount == 2)
        #expect(await operation.migrationCount == 0)
        guard case .reviewing = flow.state else {
            Issue.record("Expected a fresh review")
            return
        }
    }

    private func confirmEveryDisplayedItem(in flow: M4LegacyMigrationUIFlow) {
        guard case let .reviewing(review, _) = flow.state else {
            Issue.record("Expected reviewing state")
            return
        }
        for category in review.categories {
            flow.setCategory(category, selected: true)
        }
        for target in review.requiredTargets {
            flow.setOwnedTarget(target, selected: true)
        }
    }
}

private final class M4FFictionalBuilder:
    M4LegacyMigrationUIOperationBuilding,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let operation: any M4LegacyMigrationUIOperating
    private var count = 0

    init(operation: any M4LegacyMigrationUIOperating) {
        self.operation = operation
    }

    var creationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func makeOperation() -> any M4LegacyMigrationUIOperating {
        lock.lock()
        count += 1
        lock.unlock()
        return operation
    }
}

private actor M4FFictionalOperation: M4LegacyMigrationUIOperating {
    private let preview: M4LegacyMigrationPreview
    private let receipt: M4LegacyMigrationReceiptSummary
    private let discoveryFails: Bool
    private let migrationFails: Bool
    private(set) var discoveryCount = 0
    private(set) var migrationCount = 0
    private(set) var lastConfirmation: M4ExplicitLegacyMigrationConfirmation?

    init(
        preview: M4LegacyMigrationPreview,
        receipt: M4LegacyMigrationReceiptSummary? = nil,
        discoveryFails: Bool = false,
        migrationFails: Bool = false
    ) {
        self.preview = preview
        self.receipt = receipt ?? M4FFixtures.receipt(categories: preview.plan.categories)
        self.discoveryFails = discoveryFails
        self.migrationFails = migrationFails
    }

    func discover() throws -> M4LegacyMigrationPreview {
        discoveryCount += 1
        if discoveryFails { throw M4FSensitiveFixtureError() }
        return preview
    }

    func migrate(
        preview: M4LegacyMigrationPreview,
        confirmation: M4ExplicitLegacyMigrationConfirmation
    ) throws -> M4LegacyMigrationReceiptSummary {
        migrationCount += 1
        lastConfirmation = confirmation
        if migrationFails { throw M4FSensitiveFixtureError() }
        return receipt
    }
}

private struct M4FSensitiveFixtureError: LocalizedError {
    var errorDescription: String? {
        "\(M4FFixtures.secretText) at \(M4FFixtures.privatePath)"
    }
}

private actor M4HMockManagedCredentialPresenceChecker: M4ManagedCredentialPresenceChecking {
    private let present: Set<M4VersionedCredentialReference>
    private(set) var checkedReferences: [M4VersionedCredentialReference] = []

    init(present: Set<M4VersionedCredentialReference>) {
        self.present = present
    }

    func contains(_ reference: M4VersionedCredentialReference) -> Bool {
        checkedReferences.append(reference)
        return present.contains(reference)
    }
}

private actor M4HManagedStatusRefreshRecorder {
    private let inspector: M4ManagedRuntimeStatusInspector
    private(set) var summary = M4ManagedRuntimeSummary.empty
    private(set) var refreshCount = 0

    init(inspector: M4ManagedRuntimeStatusInspector) {
        self.inspector = inspector
    }

    func refresh() async {
        refreshCount += 1
        summary = await inspector.inspect()
    }
}

private enum M4FFixtures {
    static let secretText = "fixture-m4-5f-secret-value"
    static let privatePath = "/fictional/private/m4-5f/config.env"

    static func preview(
        categories: Set<M4LegacyConfigurationCategory> = [
            .runtimeComponents,
            .bridgeCredential,
            .asrConfiguration,
            .projectPresentation,
        ],
        unknownOwner: Bool = false,
        activeVoice: Bool = false,
        asrConflict: Bool = false
    ) -> M4LegacyMigrationPreview {
        let discovery = M4LegacyDiscovery(
            detectedCategories: categories,
            legacyFileExists: true,
            legacyFilePermissionsArePrivate: false,
            unknownRuntimeOwnerDetected: unknownOwner,
            activeVoiceWorkDetected: activeVoice
        )
        return M4LegacyMigrationPreview(
            discovery: discovery,
            plan: M4LegacyMigrationPlanner.make(from: discovery),
            asrConfigurationConflict: asrConflict
                ? .currentAppAndLegacyEnvironment
                : nil
        )
    }

    static func receipt(
        categories: [M4LegacyConfigurationCategory]
    ) -> M4LegacyMigrationReceiptSummary {
        M4LegacyMigrationReceiptSummary(
            categories: categories,
            completedOperations: [
                .preparePrivateRollback,
                .stageVersionedKeychainItems,
                .stageConfigurationFiles,
                .preservePasteIdentity,
                .validateStagedState,
                .atomicallyCommitConfiguration,
                .retainLegacyFallback,
            ],
            configurationCommitted: true,
            legacyFallbackRetained: true,
            legacyItemsDeleted: false,
            runtimeRestarted: false,
            runtimeActivationAuthorized: false,
            runtimeActivationRequired: true
        )
    }
}
