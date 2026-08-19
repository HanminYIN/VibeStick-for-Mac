import Testing

struct M4MigrationTransactionTests {
    @Test
    func redactedInspectorReturnsOnlyTypedCategoriesAndBooleans() async throws {
        let source = FictionalRedactedEvidenceSource(
            evidence: M4AcceptanceFixtures.fictionalRedactedEvidence
        )
        let inspector = M4RedactedLegacyInspector(source: source)

        let discovery = try await inspector.inspectRedactedLegacyState()

        #expect(discovery == M4AcceptanceFixtures.fictionalLegacyDiscovery)
    }

    @Test
    func migrationUsesTwoPreflightsAndKeepsActivationSeparate() async throws {
        let inspector = FictionalLegacyInspector(
            discoveries: [
                M4AcceptanceFixtures.fictionalLegacyDiscovery,
                M4AcceptanceFixtures.fictionalLegacyDiscovery,
            ]
        )
        let store = FictionalMigrationStore()
        let coordinator = M4LegacyMigrationCoordinator(inspector: inspector, store: store)

        let receipt = try await coordinator.migrate(
            authorization: M4AcceptanceFixtures.fictionalMigrationAuthorization
        )

        let inspectionCount = await inspector.inspectionCount
        let operations = await store.operations
        #expect(inspectionCount == 2)
        #expect(operations == [
            .preparePrivateRollback,
            .stageVersionedKeychainItems,
            .stageConfigurationFiles,
            .preservePasteIdentity,
            .validateStagedState,
            .atomicallyCommitConfiguration,
            .retainLegacyFallback,
        ])
        #expect(receipt.configurationCommitted)
        #expect(receipt.legacyFallbackRetained)
        #expect(!receipt.legacyItemsDeleted)
        #expect(!receipt.runtimeRestarted)
        #expect(!receipt.runtimeActivationAuthorized)
        #expect(receipt.runtimeActivationRequired)
    }

    @Test
    func changedDiscoveryBeforeMutationFailsClosed() async {
        let inspector = FictionalLegacyInspector(
            discoveries: [M4AcceptanceFixtures.fictionalBlockedLegacyDiscovery]
        )
        let store = FictionalMigrationStore()
        let coordinator = M4LegacyMigrationCoordinator(inspector: inspector, store: store)

        await #expect(throws: M4MigrationTransactionError.confirmedDiscoveryChanged) {
            _ = try await coordinator.migrate(
                authorization: M4AcceptanceFixtures.fictionalMigrationAuthorization
            )
        }
        let operations = await store.operations
        #expect(operations.isEmpty)
    }

    @Test
    func secondPreflightBlocksChangedOwnershipOrVoiceState() async {
        let inspector = FictionalLegacyInspector(
            discoveries: [
                M4AcceptanceFixtures.fictionalLegacyDiscovery,
                M4AcceptanceFixtures.fictionalBlockedLegacyDiscovery,
            ]
        )
        let store = FictionalMigrationStore()
        let coordinator = M4LegacyMigrationCoordinator(inspector: inspector, store: store)

        await #expect(throws: M4MigrationTransactionError.preflightChangedBeforeMutation) {
            _ = try await coordinator.migrate(
                authorization: M4AcceptanceFixtures.fictionalMigrationAuthorization
            )
        }
        let operations = await store.operations
        #expect(operations.isEmpty)
    }

    @Test
    func missingOwnedTargetFailsBeforeTransactionWork() async {
        let inspector = FictionalLegacyInspector(
            discoveries: [M4AcceptanceFixtures.fictionalLegacyDiscovery]
        )
        let store = FictionalMigrationStore()
        let coordinator = M4LegacyMigrationCoordinator(inspector: inspector, store: store)
        let incomplete = M4LegacyMigrationAuthorization(
            confirmedDiscovery: M4AcceptanceFixtures.fictionalLegacyDiscovery,
            confirmedCategories: M4AcceptanceFixtures.fictionalLegacyDiscovery.detectedCategories,
            ownedTargets: [.privateRollbackSnapshot]
        )

        do {
            _ = try await coordinator.migrate(authorization: incomplete)
            Issue.record("expected missing owned targets")
        } catch let error as M4MigrationTransactionError {
            #expect(error == .missingOwnedTargets([
                .existingPasteIdentity,
                .managedConfigurationFiles,
                .versionedKeychainAccounts,
            ]))
        } catch {
            Issue.record("unexpected error type")
        }
        let operations = await store.operations
        #expect(operations.isEmpty)
    }

    @Test
    func stagingFailureRestoresPreviousStateWithoutRetry() async {
        let inspector = FictionalLegacyInspector(
            discoveries: [
                M4AcceptanceFixtures.fictionalLegacyDiscovery,
                M4AcceptanceFixtures.fictionalLegacyDiscovery,
            ]
        )
        let store = FictionalMigrationStore(failingOperation: .stageConfigurationFiles)
        let coordinator = M4LegacyMigrationCoordinator(inspector: inspector, store: store)

        await #expect(throws: M4MigrationTransactionError.operationFailed(.stageConfigurationFiles)) {
            _ = try await coordinator.migrate(
                authorization: M4AcceptanceFixtures.fictionalMigrationAuthorization
            )
        }
        let operations = await store.operations
        #expect(operations == [
            .preparePrivateRollback,
            .stageVersionedKeychainItems,
            .stageConfigurationFiles,
            .restorePreviousState,
        ])
    }

    @Test
    func commitFailureRestoresPreviousStateAndDoesNotRetainFallbackAsSuccess() async {
        let inspector = FictionalLegacyInspector(
            discoveries: [
                M4AcceptanceFixtures.fictionalLegacyDiscovery,
                M4AcceptanceFixtures.fictionalLegacyDiscovery,
            ]
        )
        let store = FictionalMigrationStore(failingOperation: .atomicallyCommitConfiguration)
        let coordinator = M4LegacyMigrationCoordinator(inspector: inspector, store: store)

        await #expect(
            throws: M4MigrationTransactionError.operationFailed(.atomicallyCommitConfiguration)
        ) {
            _ = try await coordinator.migrate(
                authorization: M4AcceptanceFixtures.fictionalMigrationAuthorization
            )
        }
        let operations = await store.operations
        #expect(operations.last == .restorePreviousState)
        #expect(!operations.contains(.retainLegacyFallback))
    }

    @Test
    func unsafeStagedValidationIsRejectedAndRolledBack() async {
        let inspector = FictionalLegacyInspector(
            discoveries: [
                M4AcceptanceFixtures.fictionalLegacyDiscovery,
                M4AcceptanceFixtures.fictionalLegacyDiscovery,
            ]
        )
        let unsafeValidation = M4StagedMigrationValidation(
            rollbackDirectoryIsPrivate: true,
            rollbackFilesArePrivate: true,
            secretsUseNewVersionedAccounts: true,
            legacyKeychainItemsAreUntouched: true,
            stagedConfigurationContainsSecrets: true,
            existingPasteIdentityIsPreserved: true
        )
        let store = FictionalMigrationStore(validation: unsafeValidation)
        let coordinator = M4LegacyMigrationCoordinator(inspector: inspector, store: store)

        await #expect(throws: M4MigrationTransactionError.stagedValidationRejected) {
            _ = try await coordinator.migrate(
                authorization: M4AcceptanceFixtures.fictionalMigrationAuthorization
            )
        }
        let operations = await store.operations
        #expect(operations.last == .restorePreviousState)
        #expect(!operations.contains(.atomicallyCommitConfiguration))
    }

    @Test
    func rollbackFailureIsReportedWithoutLeakingUnderlyingError() async {
        let inspector = FictionalLegacyInspector(
            discoveries: [
                M4AcceptanceFixtures.fictionalLegacyDiscovery,
                M4AcceptanceFixtures.fictionalLegacyDiscovery,
            ]
        )
        let store = FictionalMigrationStore(
            failingOperation: .validateStagedState,
            rollbackFails: true
        )
        let coordinator = M4LegacyMigrationCoordinator(inspector: inspector, store: store)

        await #expect(
            throws: M4MigrationTransactionError.rollbackFailed(after: .validateStagedState)
        ) {
            _ = try await coordinator.migrate(
                authorization: M4AcceptanceFixtures.fictionalMigrationAuthorization
            )
        }
    }
}

private actor FictionalRedactedEvidenceSource: M4RedactedLegacyEvidenceReading {
    private let evidence: M4RedactedLegacyEvidence

    init(evidence: M4RedactedLegacyEvidence) {
        self.evidence = evidence
    }

    func readRedactedEvidence() -> M4RedactedLegacyEvidence {
        evidence
    }
}

private actor FictionalLegacyInspector: M4LegacyInspecting {
    private var discoveries: [M4LegacyDiscovery]
    private(set) var inspectionCount = 0

    init(discoveries: [M4LegacyDiscovery]) {
        self.discoveries = discoveries
    }

    func inspectRedactedLegacyState() throws -> M4LegacyDiscovery {
        inspectionCount += 1
        guard !discoveries.isEmpty else {
            throw FictionalMigrationFailure.exhaustedInspections
        }
        return discoveries.removeFirst()
    }
}

private actor FictionalMigrationStore: M4LegacyMigrationTransactionStoring {
    private(set) var operations: [M4MigrationTransactionOperation] = []
    private let failingOperation: M4MigrationTransactionOperation?
    private let rollbackFails: Bool
    private let validation: M4StagedMigrationValidation

    init(
        failingOperation: M4MigrationTransactionOperation? = nil,
        rollbackFails: Bool = false,
        validation: M4StagedMigrationValidation = M4AcceptanceFixtures.fictionalSafeStagedMigration
    ) {
        self.failingOperation = failingOperation
        self.rollbackFails = rollbackFails
        self.validation = validation
    }

    func preparePrivateRollback(for categories: [M4LegacyConfigurationCategory]) throws {
        try record(.preparePrivateRollback)
    }

    func stageVersionedKeychainItems(for categories: [M4LegacyConfigurationCategory]) throws {
        try record(.stageVersionedKeychainItems)
    }

    func stageConfigurationFiles(for categories: [M4LegacyConfigurationCategory]) throws {
        try record(.stageConfigurationFiles)
    }

    func preservePasteIdentity() throws {
        try record(.preservePasteIdentity)
    }

    func validateStagedState() throws -> M4StagedMigrationValidation {
        try record(.validateStagedState)
        return validation
    }

    func atomicallyCommitConfiguration() throws {
        try record(.atomicallyCommitConfiguration)
    }

    func retainLegacyFallback() throws {
        try record(.retainLegacyFallback)
    }

    func restorePreviousStateAndDiscardStaging() throws {
        operations.append(.restorePreviousState)
        if rollbackFails {
            throw FictionalMigrationFailure.injected
        }
    }

    private func record(_ operation: M4MigrationTransactionOperation) throws {
        operations.append(operation)
        if failingOperation == operation {
            throw FictionalMigrationFailure.injected
        }
    }
}

private enum FictionalMigrationFailure: Error {
    case exhaustedInspections
    case injected
}
