import Foundation

// M4-5B defines the transaction coordinator without wiring it to the live Mac.
// Callers must provide already-redacted evidence and an explicitly authorized
// transaction store. No default filesystem, Keychain, process, network, serial,
// firmware, App-installation, or service-control adapter exists in this layer.

struct M4RedactedLegacyEvidence: Equatable, Sendable {
    let detectedCategories: Set<M4LegacyConfigurationCategory>
    let legacyFileExists: Bool
    let legacyFilePermissionsArePrivate: Bool
    let runtimeOwnershipIsUnknown: Bool
    let activeVoiceWorkExists: Bool
}

protocol M4RedactedLegacyEvidenceReading: Sendable {
    func readRedactedEvidence() async throws -> M4RedactedLegacyEvidence
}

protocol M4LegacyInspecting: Sendable {
    func inspectRedactedLegacyState() async throws -> M4LegacyDiscovery
}

struct M4RedactedLegacyInspector: M4LegacyInspecting, Sendable {
    private let source: any M4RedactedLegacyEvidenceReading

    init(source: any M4RedactedLegacyEvidenceReading) {
        self.source = source
    }

    func inspectRedactedLegacyState() async throws -> M4LegacyDiscovery {
        let evidence = try await source.readRedactedEvidence()
        return M4LegacyDiscovery(
            detectedCategories: evidence.detectedCategories,
            legacyFileExists: evidence.legacyFileExists,
            legacyFilePermissionsArePrivate: evidence.legacyFilePermissionsArePrivate,
            unknownRuntimeOwnerDetected: evidence.runtimeOwnershipIsUnknown,
            activeVoiceWorkDetected: evidence.activeVoiceWorkExists
        )
    }
}

enum M4MigrationOwnedTarget: String, CaseIterable, Codable, Hashable, Sendable {
    case privateRollbackSnapshot = "private-rollback-snapshot"
    case versionedKeychainAccounts = "versioned-keychain-accounts"
    case managedConfigurationFiles = "managed-configuration-files"
    case existingPasteIdentity = "existing-paste-identity"
}

struct M4LegacyMigrationAuthorization: Equatable, Sendable {
    let confirmedDiscovery: M4LegacyDiscovery
    let confirmedCategories: Set<M4LegacyConfigurationCategory>
    let ownedTargets: Set<M4MigrationOwnedTarget>
}

enum M4MigrationTransactionOperation: String, CaseIterable, Codable, Equatable, Sendable {
    case preparePrivateRollback = "prepare-private-rollback"
    case stageVersionedKeychainItems = "stage-versioned-keychain-items"
    case stageConfigurationFiles = "stage-configuration-files"
    case preservePasteIdentity = "preserve-paste-identity"
    case validateStagedState = "validate-staged-state"
    case atomicallyCommitConfiguration = "atomically-commit-configuration"
    case retainLegacyFallback = "retain-legacy-fallback"
    case restorePreviousState = "restore-previous-state"
}

struct M4StagedMigrationValidation: Equatable, Sendable {
    let rollbackDirectoryIsPrivate: Bool
    let rollbackFilesArePrivate: Bool
    let secretsUseNewVersionedAccounts: Bool
    let legacyKeychainItemsAreUntouched: Bool
    let stagedConfigurationContainsSecrets: Bool
    let existingPasteIdentityIsPreserved: Bool

    func accepts(categories: Set<M4LegacyConfigurationCategory>) -> Bool {
        rollbackDirectoryIsPrivate
            && rollbackFilesArePrivate
            && legacyKeychainItemsAreUntouched
            && !stagedConfigurationContainsSecrets
            && (!categories.contains(where: \.containsSecret)
                || secretsUseNewVersionedAccounts)
            && (!categories.contains(.runtimeComponents)
                || existingPasteIdentityIsPreserved)
    }
}

protocol M4LegacyMigrationTransactionStoring: Sendable {
    func preparePrivateRollback(
        for categories: [M4LegacyConfigurationCategory]
    ) async throws
    func stageVersionedKeychainItems(
        for categories: [M4LegacyConfigurationCategory]
    ) async throws
    func stageConfigurationFiles(
        for categories: [M4LegacyConfigurationCategory]
    ) async throws
    func preservePasteIdentity() async throws
    func validateStagedState() async throws -> M4StagedMigrationValidation
    func atomicallyCommitConfiguration() async throws
    func retainLegacyFallback() async throws
    func restorePreviousStateAndDiscardStaging() async throws
}

struct M4LegacyMigrationReceiptSummary: Equatable, Sendable {
    static let schemaVersion = 1

    let categories: [M4LegacyConfigurationCategory]
    let completedOperations: [M4MigrationTransactionOperation]
    let configurationCommitted: Bool
    let legacyFallbackRetained: Bool
    let legacyItemsDeleted: Bool
    let runtimeRestarted: Bool
    let runtimeActivationAuthorized: Bool
    let runtimeActivationRequired: Bool
}

enum M4MigrationTransactionError: Error, Equatable, Sendable {
    case inspectionFailed
    case confirmedDiscoveryChanged
    case inspectionBlocked([M4LegacyMigrationBlocker])
    case categoryConfirmationMismatch
    case missingOwnedTargets([M4MigrationOwnedTarget])
    case preflightChangedBeforeMutation
    case stagedValidationRejected
    case operationFailed(M4MigrationTransactionOperation)
    case rollbackFailed(after: M4MigrationTransactionOperation)
}

actor M4LegacyMigrationCoordinator {
    private let inspector: any M4LegacyInspecting
    private let store: any M4LegacyMigrationTransactionStoring

    init(
        inspector: any M4LegacyInspecting,
        store: any M4LegacyMigrationTransactionStoring
    ) {
        self.inspector = inspector
        self.store = store
    }

    func migrate(
        authorization: M4LegacyMigrationAuthorization
    ) async throws -> M4LegacyMigrationReceiptSummary {
        let firstInspection = try await inspect()
        guard firstInspection == authorization.confirmedDiscovery else {
            throw M4MigrationTransactionError.confirmedDiscoveryChanged
        }

        let firstPlan = M4LegacyMigrationPlanner.make(from: firstInspection)
        guard firstPlan.canOfferImport else {
            throw M4MigrationTransactionError.inspectionBlocked(firstPlan.blockers)
        }
        guard authorization.confirmedCategories == firstInspection.detectedCategories else {
            throw M4MigrationTransactionError.categoryConfirmationMismatch
        }

        let requiredTargets = M4MigrationOwnedTargetPolicy.requiredTargets(
            for: authorization.confirmedCategories
        )
        let missingTargets = requiredTargets
            .subtracting(authorization.ownedTargets)
            .sorted { $0.rawValue < $1.rawValue }
        guard missingTargets.isEmpty else {
            throw M4MigrationTransactionError.missingOwnedTargets(missingTargets)
        }

        let secondInspection = try await inspect()
        let secondPlan = M4LegacyMigrationPlanner.make(from: secondInspection)
        guard secondInspection == firstInspection, secondPlan.canOfferImport else {
            throw M4MigrationTransactionError.preflightChangedBeforeMutation
        }

        let categories = authorization.confirmedCategories.sorted { $0.rawValue < $1.rawValue }
        let secretCategories = categories.filter { $0.containsSecret }
        let configurationCategories = categories.filter { $0.requiresConfigurationWrite }
        var completedOperations: [M4MigrationTransactionOperation] = []

        do {
            try await perform(.preparePrivateRollback) {
                try await store.preparePrivateRollback(for: categories)
            }
            completedOperations.append(.preparePrivateRollback)

            if !secretCategories.isEmpty {
                try await perform(.stageVersionedKeychainItems) {
                    try await store.stageVersionedKeychainItems(for: secretCategories)
                }
                completedOperations.append(.stageVersionedKeychainItems)
            }

            if !configurationCategories.isEmpty {
                try await perform(.stageConfigurationFiles) {
                    try await store.stageConfigurationFiles(for: configurationCategories)
                }
                completedOperations.append(.stageConfigurationFiles)
            }

            if authorization.confirmedCategories.contains(.runtimeComponents) {
                try await perform(.preservePasteIdentity) {
                    try await store.preservePasteIdentity()
                }
                completedOperations.append(.preservePasteIdentity)
            }

            let validation = try await perform(.validateStagedState) {
                try await store.validateStagedState()
            }
            guard validation.accepts(categories: authorization.confirmedCategories) else {
                throw M4MigrationTransactionError.stagedValidationRejected
            }
            completedOperations.append(.validateStagedState)

            try await perform(.atomicallyCommitConfiguration) {
                try await store.atomicallyCommitConfiguration()
            }
            completedOperations.append(.atomicallyCommitConfiguration)

            try await perform(.retainLegacyFallback) {
                try await store.retainLegacyFallback()
            }
            completedOperations.append(.retainLegacyFallback)
        } catch let failure as M4MigrationTransactionError {
            do {
                try await store.restorePreviousStateAndDiscardStaging()
            } catch {
                throw M4MigrationTransactionError.rollbackFailed(
                    after: failure.failedOperation ?? .preparePrivateRollback
                )
            }
            throw failure
        }

        return M4LegacyMigrationReceiptSummary(
            categories: categories,
            completedOperations: completedOperations,
            configurationCommitted: true,
            legacyFallbackRetained: true,
            legacyItemsDeleted: false,
            runtimeRestarted: false,
            runtimeActivationAuthorized: false,
            runtimeActivationRequired: true
        )
    }

    private func inspect() async throws -> M4LegacyDiscovery {
        do {
            return try await inspector.inspectRedactedLegacyState()
        } catch {
            throw M4MigrationTransactionError.inspectionFailed
        }
    }

    private func perform<Value: Sendable>(
        _ operation: M4MigrationTransactionOperation,
        action: () async throws -> Value
    ) async throws -> Value {
        do {
            return try await action()
        } catch {
            throw M4MigrationTransactionError.operationFailed(operation)
        }
    }

}

private extension M4MigrationTransactionError {
    var failedOperation: M4MigrationTransactionOperation? {
        if self == .stagedValidationRejected {
            return .validateStagedState
        }
        guard case let .operationFailed(operation) = self else { return nil }
        return operation
    }
}
