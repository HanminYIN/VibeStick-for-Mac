import Foundation
import Testing

struct M4ProductionMigrationAdaptersTests {
    @Test
    func productionLocationsRejectTraversalAndConfineEveryOwnedPath() throws {
        let root = URL(fileURLWithPath: "/fictional/VibeStick-M4-5D", isDirectory: true)
        let locations = try M4ProductionMigrationLocations.make(
            supportDirectory: root,
            transactionIdentifier: "m4-5d-fixture-001"
        )

        #expect(locations.transactionsDirectory.path.hasPrefix(root.path + "/"))
        #expect(locations.transactionRoot.path.hasPrefix(root.path + "/"))
        #expect(locations.rollbackDirectory.path.hasPrefix(root.path + "/"))
        #expect(locations.stagingDirectory.path.hasPrefix(root.path + "/"))
        #expect(locations.stagedConfiguration.path.hasPrefix(root.path + "/"))
        #expect(locations.committedConfiguration.path.hasPrefix(root.path + "/"))
        #expect(locations.fallbackMarker.path.hasPrefix(root.path + "/"))
        #expect(throws: M4ProductionMigrationAdapterError.unsafeLocation) {
            _ = try M4ProductionMigrationLocations.make(
                supportDirectory: root,
                transactionIdentifier: "../escape"
            )
        }
    }

    @Test
    func keychainVaultStagesOnlyFixedManagedAccounts() async throws {
        let client = FictionalVersionedGenericPasswordClient()
        let vault = M4VersionedKeychainCredentialVault(client: client)
        let bridge = M4VersionedCredentialReference.managed(.bridgeToken)
        let asr = M4VersionedCredentialReference.managed(.asrAPIKey)

        try await vault.stage(Data("fixture-bridge-m4-5d".utf8), for: bridge)
        try await vault.stage(Data("fixture-asr-m4-5d".utf8), for: asr)

        #expect(try await vault.contains(bridge))
        #expect(try await vault.contains(asr))
        #expect(await vault.legacyAccountsRemainUntouched())
        let touched = await client.touchedReferences
        #expect(touched == [bridge, asr])
        #expect(!touched.map(\.account).contains(KeychainSecret.bridgeToken.rawValue))
        #expect(!touched.map(\.account).contains(KeychainSecret.asrAPIKey.rawValue))
    }

    @Test
    func keychainVaultRefusesAPreexistingManagedAccountWithoutOverwriteOrDelete() async throws {
        let bridge = M4VersionedCredentialReference.managed(.bridgeToken)
        let previous = Data("fixture-preexisting-managed-value".utf8)
        let client = FictionalVersionedGenericPasswordClient(initialItems: [bridge: previous])
        let vault = M4VersionedKeychainCredentialVault(client: client)

        await #expect(
            throws: M4ProductionMigrationAdapterError.managedCredentialAlreadyExists
        ) {
            try await vault.stage(Data("fixture-replacement-must-not-land".utf8), for: bridge)
        }

        #expect(try await client.read(bridge) == previous)
        #expect(await client.addedReferences.isEmpty)
        #expect(await client.deletedReferences.isEmpty)
    }

    @Test
    func discardDeletesOnlyAnItemCreatedByThisVault() async throws {
        let bridge = M4VersionedCredentialReference.managed(.bridgeToken)
        let asr = M4VersionedCredentialReference.managed(.asrAPIKey)
        let client = FictionalVersionedGenericPasswordClient()
        let vault = M4VersionedKeychainCredentialVault(client: client)

        try await vault.stage(Data("fixture-created-bridge".utf8), for: bridge)
        try await vault.discard(asr)
        #expect(await client.deletedReferences.isEmpty)

        try await vault.discard(bridge)
        #expect(await client.deletedReferences == [bridge])
        #expect(try await client.contains(bridge) == false)
    }

    @Test
    func failedDiscardRemainsRetryableWithoutTouchingAnotherAccount() async throws {
        let bridge = M4VersionedCredentialReference.managed(.bridgeToken)
        let asr = M4VersionedCredentialReference.managed(.asrAPIKey)
        let client = FictionalVersionedGenericPasswordClient(
            failingDeletes: [bridge]
        )
        let vault = M4VersionedKeychainCredentialVault(client: client)
        try await vault.stage(Data("fixture-retryable-bridge".utf8), for: bridge)

        await #expect(throws: M4DFictionalFailure.injectedDeleteFailure) {
            try await vault.discard(bridge)
        }
        #expect(try await client.contains(bridge))
        #expect(await client.deletedReferences.isEmpty)

        await client.allowDelete(bridge)
        try await vault.discard(bridge)
        try await vault.discard(asr)
        #expect(await client.deletedReferences == [bridge])
    }

    @Test
    func fullProductionTransactionUsesOnlyInjectedFictionalIO() async throws {
        let context = try await makeContext(transactionIdentifier: "m4-5d-fixture-full")
        let inspector = M4DFictionalInspector(
            discoveries: [
                M4AcceptanceFixtures.fictionalLegacyDiscovery,
                M4AcceptanceFixtures.fictionalLegacyDiscovery,
            ]
        )
        let coordinator = M4LegacyMigrationCoordinator(
            inspector: inspector,
            store: context.store
        )

        let receipt = try await coordinator.migrate(
            authorization: M4AcceptanceFixtures.fictionalMigrationAuthorization
        )

        let committed = try await context.fileSystem.readFile(
            at: context.locations.committedConfiguration
        )
        let text = String(decoding: committed, as: UTF8.self)
        #expect(receipt.configurationCommitted)
        #expect(receipt.legacyFallbackRetained)
        #expect(!receipt.legacyItemsDeleted)
        #expect(!receipt.runtimeRestarted)
        #expect(!receipt.runtimeActivationAuthorized)
        #expect(try await context.fileSystem.permissions(
            at: context.locations.committedConfiguration
        ) == 0o600)
        #expect(try await context.fileSystem.permissions(
            at: context.locations.rollbackDirectory
        ) == 0o700)
        #expect(try await context.fileSystem.itemExists(at: context.locations.fallbackMarker))
        #expect(!text.contains(M4AcceptanceFixtures.fictionalBridgeSecret))
        #expect(!text.contains(M4AcceptanceFixtures.fictionalASRSecret))
        #expect(await context.fileSystem.operationCount > 0)
        #expect(await context.keychainClient.addedReferences == [
            .managed(.bridgeToken),
            .managed(.asrAPIKey),
        ])
    }

    @Test
    func restoreAfterCommitReinstatesPreviousConfigurationAndDiscardsStagedCredentials() async throws {
        let previous = Data("{\"schemaVersion\":0,\"fixture\":true}".utf8)
        let context = try await makeContext(
            transactionIdentifier: "m4-5d-fixture-restore",
            previousConfiguration: previous
        )
        let categories = M4AcceptanceFixtures.fictionalLegacyDiscovery.detectedCategories
            .sorted { $0.rawValue < $1.rawValue }
        try await context.store.preparePrivateRollback(for: categories)
        try await context.store.stageVersionedKeychainItems(
            for: categories.filter(\.containsSecret)
        )
        try await context.store.stageConfigurationFiles(
            for: categories.filter(\.requiresConfigurationWrite)
        )
        try await context.store.preservePasteIdentity()
        let validation = try await context.store.validateStagedState()
        #expect(validation.accepts(categories: Set(categories)))
        try await context.store.atomicallyCommitConfiguration()

        try await context.store.restorePreviousStateAndDiscardStaging()

        #expect(try await context.fileSystem.readFile(
            at: context.locations.committedConfiguration
        ) == previous)
        #expect(await context.keychainClient.deletedReferences == [
            .managed(.bridgeToken),
            .managed(.asrAPIKey),
        ])
    }

    @Test
    func validationRejectsRelaxedRollbackPermissionsInInjectedFilesystem() async throws {
        let context = try await makeContext(transactionIdentifier: "m4-5d-fixture-permissions")
        let categories = M4AcceptanceFixtures.fictionalLegacyDiscovery.detectedCategories
            .sorted { $0.rawValue < $1.rawValue }
        try await context.store.preparePrivateRollback(for: categories)
        try await context.store.stageVersionedKeychainItems(
            for: categories.filter(\.containsSecret)
        )
        try await context.store.stageConfigurationFiles(
            for: categories.filter(\.requiresConfigurationWrite)
        )
        try await context.store.preservePasteIdentity()
        try await context.fileSystem.setPermissions(
            0o755,
            at: context.locations.rollbackDirectory
        )

        let validation = try await context.store.validateStagedState()

        #expect(!validation.rollbackDirectoryIsPrivate)
        #expect(!validation.accepts(categories: Set(categories)))
        try await context.store.restorePreviousStateAndDiscardStaging()
    }

    @Test
    func categoryMismatchFailsBeforeInjectedFilesystemOrKeychainMutation() async throws {
        let context = try await makeContext(transactionIdentifier: "m4-5d-fixture-categories")

        await #expect(throws: M4ProductionMigrationAdapterError.categoryRequestMismatch) {
            try await context.store.preparePrivateRollback(for: [.bridgeCredential])
        }

        #expect(await context.fileSystem.operationCount == 0)
        #expect(await context.keychainClient.touchedReferences.isEmpty)
    }

    private func makeContext(
        transactionIdentifier: String,
        previousConfiguration: Data? = nil
    ) async throws -> M4DFictionalContext {
        let root = URL(fileURLWithPath: "/fictional/VibeStick-M4-5D", isDirectory: true)
        let locations = try M4ProductionMigrationLocations.make(
            supportDirectory: root,
            transactionIdentifier: transactionIdentifier
        )
        let fileSystem = M4DFictionalMigrationFileSystem()
        if let previousConfiguration {
            await fileSystem.seedFile(
                previousConfiguration,
                at: locations.committedConfiguration,
                permissions: 0o600
            )
        }
        let client = FictionalVersionedGenericPasswordClient()
        let vault = M4VersionedKeychainCredentialVault(client: client)
        let store = try M4ProductionMigrationTransactionStore(
            locations: locations,
            payload: M4AcceptanceFixtures.fictionalOfflineMigrationPayload,
            credentialVault: vault,
            fileSystem: fileSystem
        )
        return M4DFictionalContext(
            locations: locations,
            fileSystem: fileSystem,
            keychainClient: client,
            store: store
        )
    }
}

private struct M4DFictionalContext: Sendable {
    let locations: M4ProductionMigrationLocations
    let fileSystem: M4DFictionalMigrationFileSystem
    let keychainClient: FictionalVersionedGenericPasswordClient
    let store: M4ProductionMigrationTransactionStore
}

private actor M4DFictionalInspector: M4LegacyInspecting {
    private var discoveries: [M4LegacyDiscovery]

    init(discoveries: [M4LegacyDiscovery]) {
        self.discoveries = discoveries
    }

    func inspectRedactedLegacyState() throws -> M4LegacyDiscovery {
        guard !discoveries.isEmpty else { throw M4DFictionalFailure.exhaustedInspections }
        return discoveries.removeFirst()
    }
}

private actor FictionalVersionedGenericPasswordClient: M4VersionedGenericPasswordAccess {
    private var items: [M4VersionedCredentialReference: Data]
    private var failingDeletes: Set<M4VersionedCredentialReference>
    private(set) var addedReferences: [M4VersionedCredentialReference] = []
    private(set) var deletedReferences: [M4VersionedCredentialReference] = []
    private(set) var touchedReferences: [M4VersionedCredentialReference] = []

    init(
        initialItems: [M4VersionedCredentialReference: Data] = [:],
        failingDeletes: Set<M4VersionedCredentialReference> = []
    ) {
        self.items = initialItems
        self.failingDeletes = failingDeletes
    }

    func allowDelete(_ reference: M4VersionedCredentialReference) {
        failingDeletes.remove(reference)
    }

    func contains(_ reference: M4VersionedCredentialReference) -> Bool {
        touch(reference)
        return items[reference] != nil
    }

    func read(_ reference: M4VersionedCredentialReference) -> Data? {
        touch(reference)
        return items[reference]
    }

    func add(_ data: Data, for reference: M4VersionedCredentialReference) throws {
        touch(reference)
        guard items[reference] == nil else { throw M4DFictionalFailure.duplicateItem }
        items[reference] = data
        addedReferences.append(reference)
    }

    func delete(_ reference: M4VersionedCredentialReference) throws {
        touch(reference)
        guard !failingDeletes.contains(reference) else {
            throw M4DFictionalFailure.injectedDeleteFailure
        }
        items.removeValue(forKey: reference)
        deletedReferences.append(reference)
    }

    private func touch(_ reference: M4VersionedCredentialReference) {
        if !touchedReferences.contains(reference) {
            touchedReferences.append(reference)
        }
    }
}

private actor M4DFictionalMigrationFileSystem: M4MigrationFileSystemAccess {
    private enum Entry: Sendable {
        case directory(permissions: Int)
        case file(data: Data, permissions: Int)
    }

    private var entries: [String: Entry] = [:]
    private(set) var operationCount = 0

    func seedFile(_ data: Data, at url: URL, permissions: Int) {
        entries[url.standardizedFileURL.path] = .file(data: data, permissions: permissions)
    }

    func setPermissions(_ permissions: Int, at url: URL) throws {
        let path = url.standardizedFileURL.path
        guard let entry = entries[path] else { throw M4DFictionalFailure.missingItem }
        switch entry {
        case .directory:
            entries[path] = .directory(permissions: permissions)
        case let .file(data, _):
            entries[path] = .file(data: data, permissions: permissions)
        }
    }

    func itemExists(at url: URL) -> Bool {
        operationCount += 1
        return entries[url.standardizedFileURL.path] != nil
    }

    func readFile(at url: URL) throws -> Data {
        operationCount += 1
        guard case let .file(data, _)? = entries[url.standardizedFileURL.path] else {
            throw M4DFictionalFailure.missingItem
        }
        return data
    }

    func createPrivateDirectory(at url: URL) {
        operationCount += 1
        entries[url.standardizedFileURL.path] = .directory(permissions: 0o700)
    }

    func writePrivateFile(_ data: Data, to url: URL, atomically: Bool) {
        operationCount += 1
        entries[url.standardizedFileURL.path] = .file(data: data, permissions: 0o600)
    }

    func removeItem(at url: URL) {
        operationCount += 1
        let path = url.standardizedFileURL.path
        let prefix = path.hasSuffix("/") ? path : path + "/"
        entries = entries.filter { key, _ in key != path && !key.hasPrefix(prefix) }
    }

    func contentsOfDirectory(at url: URL) -> [URL] {
        operationCount += 1
        let parent = url.standardizedFileURL.path
        return entries.keys.compactMap { path in
            let candidate = URL(fileURLWithPath: path)
            return candidate.deletingLastPathComponent().path == parent ? candidate : nil
        }.sorted { $0.path < $1.path }
    }

    func permissions(at url: URL) throws -> Int? {
        operationCount += 1
        guard let entry = entries[url.standardizedFileURL.path] else {
            throw M4DFictionalFailure.missingItem
        }
        switch entry {
        case let .directory(permissions), let .file(_, permissions):
            return permissions
        }
    }
}

private enum M4DFictionalFailure: Error {
    case duplicateItem
    case exhaustedInspections
    case injectedDeleteFailure
    case missingItem
}
