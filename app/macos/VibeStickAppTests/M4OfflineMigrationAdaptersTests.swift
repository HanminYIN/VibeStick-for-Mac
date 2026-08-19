import Foundation
import Testing

struct M4OfflineMigrationAdaptersTests {
    @Test
    func versionedReferencesUseFixedNewAccounts() {
        let bridge = M4VersionedCredentialReference.managed(.bridgeToken)
        let asr = M4VersionedCredentialReference.managed(.asrAPIKey)

        #expect(bridge.schemaVersion == 1)
        #expect(bridge.storage == "macos-keychain")
        #expect(bridge.service == "io.github.hanminyin.vibestick")
        #expect(bridge.account == "bridge-token-v1")
        #expect(asr.account == "asr-api-key-v1")
        #expect(bridge.isManagedVersion)
        #expect(asr.isManagedVersion)
        #expect(bridge.account != KeychainSecret.bridgeToken.rawValue)
        #expect(asr.account != KeychainSecret.asrAPIKey.rawValue)
    }

    @Test
    func offlineStoreRejectsAnyRootOutsideTheTemporaryDirectory() {
        #expect(throws: M4OfflineMigrationAdapterError.rootOutsideTemporaryDirectory) {
            _ = try M4OfflineMigrationTransactionStore(
                sandboxRoot: URL(fileURLWithPath: "/Applications/VibeStick-M4-5C-Fixture"),
                payload: M4AcceptanceFixtures.fictionalOfflineMigrationPayload,
                credentialVault: FictionalVersionedCredentialVault()
            )
        }
    }

    @Test
    func offlineStoreDoesNotReuseAnExistingTransactionRoot() async throws {
        let sandbox = makeTemporarySandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let store = try M4OfflineMigrationTransactionStore(
            sandboxRoot: sandbox,
            payload: M4AcceptanceFixtures.fictionalOfflineMigrationPayload,
            credentialVault: FictionalVersionedCredentialVault()
        )
        try FileManager.default.createDirectory(
            at: store.locations.transactionRoot,
            withIntermediateDirectories: true
        )
        let categories = M4AcceptanceFixtures.fictionalLegacyDiscovery.detectedCategories
            .sorted { $0.rawValue < $1.rawValue }

        await #expect(throws: M4OfflineMigrationAdapterError.transactionRootAlreadyExists) {
            try await store.preparePrivateRollback(for: categories)
        }
    }

    @Test
    func fullOfflineTransactionProducesPrivateSecretFreeRuntimeConfiguration() async throws {
        let sandbox = makeTemporarySandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let vault = FictionalVersionedCredentialVault()
        let store = try M4OfflineMigrationTransactionStore(
            sandboxRoot: sandbox,
            payload: M4AcceptanceFixtures.fictionalOfflineMigrationPayload,
            credentialVault: vault
        )
        let inspector = M4CFixtureInspector(
            discoveries: [
                M4AcceptanceFixtures.fictionalLegacyDiscovery,
                M4AcceptanceFixtures.fictionalLegacyDiscovery,
            ]
        )
        let coordinator = M4LegacyMigrationCoordinator(inspector: inspector, store: store)

        let receipt = try await coordinator.migrate(
            authorization: M4AcceptanceFixtures.fictionalMigrationAuthorization
        )

        let locations = store.locations
        let data = try Data(contentsOf: locations.committedConfiguration)
        let text = String(decoding: data, as: UTF8.self)
        let configPermissions = try permissions(at: locations.committedConfiguration)
        let rollbackPermissions = try permissions(at: locations.rollbackDirectory)
        #expect(receipt.configurationCommitted)
        #expect(!receipt.runtimeRestarted)
        #expect(!receipt.runtimeActivationAuthorized)
        #expect(configPermissions == 0o600)
        #expect(rollbackPermissions == 0o700)
        #expect(!text.contains(M4AcceptanceFixtures.fictionalBridgeSecret))
        #expect(!text.contains(M4AcceptanceFixtures.fictionalASRSecret))
        #expect(FileManager.default.fileExists(atPath: locations.fallbackMarker.path))

        let resolved = try await M4BridgeRuntimeConfigurationResolver(
            credentialVault: vault
        ).resolve(data)
        #expect(resolved.bridgeToken == M4AcceptanceFixtures.fictionalBridgeSecret)
        #expect(resolved.asrAPIKey == M4AcceptanceFixtures.fictionalASRSecret)
        #expect(resolved.managedConfiguration.agentProvider == "auto")
        #expect(await vault.legacyAccountsRemainUntouched())
    }

    @Test
    func stagedValidationDetectsRelaxedRollbackPermissions() async throws {
        let sandbox = makeTemporarySandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let vault = FictionalVersionedCredentialVault()
        let store = try M4OfflineMigrationTransactionStore(
            sandboxRoot: sandbox,
            payload: M4AcceptanceFixtures.fictionalOfflineMigrationPayload,
            credentialVault: vault
        )
        let categories = M4AcceptanceFixtures.fictionalLegacyDiscovery.detectedCategories
            .sorted { $0.rawValue < $1.rawValue }
        try await store.preparePrivateRollback(for: categories)
        try await store.stageVersionedKeychainItems(
            for: categories.filter(\.containsSecret)
        )
        try await store.stageConfigurationFiles(
            for: categories.filter(\.requiresConfigurationWrite)
        )
        try await store.preservePasteIdentity()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: store.locations.rollbackDirectory.path
        )

        let validation = try await store.validateStagedState()

        #expect(!validation.rollbackDirectoryIsPrivate)
        #expect(!validation.accepts(categories: Set(categories)))
        try await store.restorePreviousStateAndDiscardStaging()
    }

    @Test
    func managedConfigurationCannotContainASelectedSecret() async throws {
        let sandbox = makeTemporarySandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let secret = M4AcceptanceFixtures.fictionalBridgeSecret
        let payload = M4AcceptanceFixtures.fictionalOfflineMigrationPayload(
            projectName: secret
        )
        let store = try M4OfflineMigrationTransactionStore(
            sandboxRoot: sandbox,
            payload: payload,
            credentialVault: FictionalVersionedCredentialVault()
        )
        let categories = payload.categories.sorted { $0.rawValue < $1.rawValue }
        try await store.preparePrivateRollback(for: categories)
        try await store.stageVersionedKeychainItems(for: categories.filter(\.containsSecret))

        await #expect(throws: M4OfflineMigrationAdapterError.secretEnteredManagedConfiguration) {
            try await store.stageConfigurationFiles(
                for: categories.filter(\.requiresConfigurationWrite)
            )
        }
        try await store.restorePreviousStateAndDiscardStaging()
    }

    @Test
    func restoreAfterCommitReinstatesTheExactPreviousConfiguration() async throws {
        let sandbox = makeTemporarySandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        let previous = Data("{\"schemaVersion\":0,\"fixture\":true}".utf8)
        let committed = sandbox.appendingPathComponent("managed-runtime-v1.json")
        try previous.write(to: committed)
        let payload = M4AcceptanceFixtures.fictionalOfflineMigrationPayload
        let store = try M4OfflineMigrationTransactionStore(
            sandboxRoot: sandbox,
            payload: payload,
            credentialVault: FictionalVersionedCredentialVault()
        )
        let categories = payload.categories.sorted { $0.rawValue < $1.rawValue }
        try await store.preparePrivateRollback(for: categories)
        try await store.stageVersionedKeychainItems(for: categories.filter(\.containsSecret))
        try await store.stageConfigurationFiles(for: categories.filter(\.requiresConfigurationWrite))
        try await store.preservePasteIdentity()
        let validation = try await store.validateStagedState()
        #expect(validation.accepts(categories: payload.categories))
        try await store.atomicallyCommitConfiguration()

        try await store.restorePreviousStateAndDiscardStaging()

        #expect(try Data(contentsOf: committed) == previous)
    }

    @Test
    func localCommandRuntimeConfigurationDoesNotResolveASRCredential() async throws {
        let vault = FictionalVersionedCredentialVault()
        let config = M4ManagedRuntimeConfiguration(
            schemaVersion: 1,
            credentialReferences: [],
            asr: M4ManagedASRConfiguration(
                provider: "local-command",
                baseURL: "",
                model: "",
                language: "zh",
                localCommand: "/fixture/transcribe"
            ),
            agentProvider: nil,
            projectPresentation: nil,
            voiceDelivery: nil,
            soundEnabled: nil
        )
        let data = try JSONEncoder().encode(config)

        let result = try await M4BridgeRuntimeConfigurationResolver(
            credentialVault: vault
        ).resolve(data)

        #expect(result.asrAPIKey == nil)
        #expect(await vault.readCount == 0)
    }

    private func makeTemporarySandbox() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("VibeStick-M4-5C-\(UUID().uuidString)", isDirectory: true)
    }

    private func permissions(at url: URL) throws -> Int? {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue
    }
}

private actor M4CFixtureInspector: M4LegacyInspecting {
    private var discoveries: [M4LegacyDiscovery]

    init(discoveries: [M4LegacyDiscovery]) {
        self.discoveries = discoveries
    }

    func inspectRedactedLegacyState() throws -> M4LegacyDiscovery {
        guard !discoveries.isEmpty else { throw M4CFixtureFailure.exhaustedInspections }
        return discoveries.removeFirst()
    }
}

private actor FictionalVersionedCredentialVault: M4OfflineCredentialVault {
    private var items: [M4VersionedCredentialReference: Data] = [:]
    private var legacyAccountsChanged = false
    private(set) var readCount = 0

    func stage(_ secret: Data, for reference: M4VersionedCredentialReference) throws {
        guard reference.isManagedVersion else {
            throw M4OfflineMigrationAdapterError.invalidCredentialReference
        }
        items[reference] = secret
    }

    func read(_ reference: M4VersionedCredentialReference) -> Data? {
        readCount += 1
        return items[reference]
    }

    func contains(_ reference: M4VersionedCredentialReference) -> Bool {
        items[reference] != nil
    }

    func discard(_ reference: M4VersionedCredentialReference) {
        items.removeValue(forKey: reference)
    }

    func legacyAccountsRemainUntouched() -> Bool {
        !legacyAccountsChanged
    }
}

private enum M4CFixtureFailure: Error {
    case exhaustedInspections
}
