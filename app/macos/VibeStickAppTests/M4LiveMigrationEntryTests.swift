import Foundation
import Testing

struct M4LiveMigrationEntryTests {
    @Test
    func fileAndCredentialScopesAreFixedAndDoNotAcceptArbitraryNames() throws {
        let root = URL(fileURLWithPath: "/fictional/M4-5E-Support", isDirectory: true)
        let allowlist = try M4LegacyFileAllowlist(supportDirectory: root)

        #expect(allowlist.allowedURLs == Set([
            root.appendingPathComponent(".env"),
            root.appendingPathComponent("config-v1.json"),
            root.appendingPathComponent("device-config-v1.json"),
            root.appendingPathComponent("recording.json"),
        ]))
        #expect(M4LegacyCredentialReference.service == "io.github.hanminyin.vibestick")
        #expect(M4LegacyCredentialReference.legacy(.bridgeToken).account == "bridge-token")
        #expect(M4LegacyCredentialReference.legacy(.asrAPIKey).account == "asr-api-key")
        #expect(M4LegacyCredentialReference.legacy(.bridgeToken).isAllowedLegacyReference)
        #expect(M4LegacyCredentialReference.legacy(.asrAPIKey).isAllowedLegacyReference)
        #expect(M4LegacyCredentialReference.legacy(.bridgeToken).account
            != M4VersionedCredentialReference.managed(.bridgeToken).account)
    }

    @Test
    func restrictedMapperProducesCompletePayloadWithoutPuttingSecretsInConfiguration() async throws {
        let environment = Data(
            """
            VIBE_STICK_PROVIDER=auto
            VIBE_STICK_BRIDGE_TOKEN=fixture-env-bridge-m4-5e
            VIBE_STICK_ASR_PROVIDER=groq
            VIBE_STICK_ASR_BASE_URL=https://api.groq.com/openai/v1
            VIBE_STICK_ASR_API_KEY=fixture-env-asr-m4-5e
            VIBE_STICK_ASR_MODEL=whisper-large-v3-turbo
            VIBE_STICK_ASR_LANGUAGE=zh
            VIBE_STICK_PROJECT_NAME=Fictional Workspace
            VIBE_STICK_SEND_MODE=confirm
            """.utf8
        )
        let files = M4EFictionalFileReader(snapshots: [
            .legacyEnvironment: M4RestrictedLegacyFileSnapshot(
                source: .legacyEnvironment,
                exists: true,
                data: environment,
                permissions: 0o644
            ),
            .recordingState: M4RestrictedLegacyFileSnapshot(
                source: .recordingState,
                exists: true,
                data: Data("{\"status\":\"idle\"}".utf8),
                permissions: 0o600
            ),
        ])
        let credentialReader = M4EFictionalCredentialReader(values: [
            .bridgeToken: Data("fixture-keychain-bridge-m4-5e".utf8),
            .asrAPIKey: Data("fixture-keychain-asr-m4-5e".utf8),
        ])
        let runtime = M4EFictionalRuntimeFactsReader(facts: M4LegacyRuntimeFacts(
            runtimeComponentsInstalled: true,
            runtimeOwnershipIsUnknown: false,
            activeVoiceWorkExists: false,
            pasteIdentity: "io.example.vibestick.paste.fixture",
            accessibilityPermissionGranted: true,
            soundEnabled: true
        ))
        let source = M4RestrictedLegacyMigrationSource(
            files: files,
            credentials: credentialReader,
            runtime: runtime
        )

        let prepared = try await source.readPreparedLegacyMigration(
            asrConfigurationSource: nil
        )
        let encodedConfiguration = try JSONEncoder().encode(prepared.payload.managedConfiguration)
        let text = String(decoding: encodedConfiguration, as: UTF8.self)

        #expect(prepared.evidence.detectedCategories
            == M4AcceptanceFixtures.fictionalLegacyDiscovery.detectedCategories)
        #expect(!prepared.evidence.legacyFilePermissionsArePrivate)
        #expect(prepared.payload.credentialSecrets[.bridgeToken]
            == Data("fixture-keychain-bridge-m4-5e".utf8))
        #expect(prepared.payload.credentialSecrets[.asrAPIKey]
            == Data("fixture-keychain-asr-m4-5e".utf8))
        #expect(prepared.payload.rollbackArtifacts.map(\.fileName)
            == ["legacy-environment-v1.env"])
        #expect(!text.contains("fixture-keychain-bridge-m4-5e"))
        #expect(!text.contains("fixture-keychain-asr-m4-5e"))
        #expect(!text.contains("fixture-env-bridge-m4-5e"))
        #expect(!text.contains("fixture-env-asr-m4-5e"))
    }

    @Test
    func previewContainsOnlyRedactedDiscoveryAndPlan() async throws {
        let source = M4EPreparedSource(
            prepared: []
        )
        let builder = M4EStoreBuilder(store: M4EFictionalStore())
        let entry = M4ExplicitLegacyMigrationEntry(source: source, builder: builder)

        let preview = try await entry.discover()
        let reflected = String(reflecting: preview)

        #expect(preview.discovery == M4AcceptanceFixtures.fictionalLegacyDiscovery)
        #expect(preview.plan.canOfferImport)
        #expect(!reflected.contains(M4AcceptanceFixtures.fictionalBridgeSecret))
        #expect(!reflected.contains(M4AcceptanceFixtures.fictionalASRSecret))
        #expect(!reflected.contains("/fictional/"))
        #expect(await source.previewCount == 1)
        #expect(await source.readCount == 0)
        #expect(await builder.creationCount == 0)
    }

    @Test
    func restrictedPreviewChecksCredentialPresenceWithoutReadingContents() async throws {
        let credentialReader = M4EFictionalCredentialReader(values: [
            .bridgeToken: Data("fixture-preview-bridge-m4-5e".utf8),
            .asrAPIKey: Data("fixture-preview-asr-m4-5e".utf8),
        ])
        let source = M4RestrictedLegacyMigrationSource(
            files: M4EFictionalFileReader(snapshots: [:]),
            credentials: credentialReader,
            runtime: M4EFictionalRuntimeFactsReader(facts: M4EFixtures.idleRuntime)
        )
        let entry = M4ExplicitLegacyMigrationEntry(
            source: source,
            builder: M4EStoreBuilder(store: M4EFictionalStore())
        )

        let preview = try await entry.discover()

        #expect(preview.discovery.detectedCategories == [.bridgeCredential, .asrCredential])
        #expect(await credentialReader.containsCount == 2)
        #expect(await credentialReader.readCount == 0)
    }

    @Test
    func conflictingASRDiscoveryPublishesOnlyFixedSourceLabels() async throws {
        let (source, credentialReader) = try m4EConflictingRestrictedSource()
        let entry = M4ExplicitLegacyMigrationEntry(
            source: source,
            builder: M4EStoreBuilder(store: M4EFictionalStore())
        )

        let preview = try await entry.discover()
        let reflected = String(reflecting: preview)

        #expect(preview.asrConfigurationConflict == .currentAppAndLegacyEnvironment)
        #expect(preview.discovery.detectedCategories.contains(.asrConfiguration))
        #expect(preview.discovery.detectedCategories.contains(.asrCredential))
        #expect(await credentialReader.containsCount == 2)
        #expect(await credentialReader.readCount == 0)
        #expect(!reflected.contains("api.siliconflow.cn"))
        #expect(!reflected.contains("api.groq.com"))
        #expect(!reflected.contains("whisper-large-v3-turbo"))
        #expect(!reflected.contains("fixture-conflict-asr-secret"))
    }

    @Test
    func preparedConflictUsesOnlyTheExplicitlySelectedASRSource() async throws {
        let (currentSource, _) = try m4EConflictingRestrictedSource()
        let current = try await currentSource.readPreparedLegacyMigration(
            asrConfigurationSource: .currentApp
        )
        let (legacySource, _) = try m4EConflictingRestrictedSource()
        let legacy = try await legacySource.readPreparedLegacyMigration(
            asrConfigurationSource: .legacyEnvironment
        )

        #expect(current.resolvedASRConfigurationSource == .currentApp)
        #expect(current.payload.managedConfiguration.asr?.provider == "siliconflow")
        #expect(legacy.resolvedASRConfigurationSource == .legacyEnvironment)
        #expect(legacy.payload.managedConfiguration.asr?.provider == "groq")
        #expect(current.payload.managedConfiguration.asr
            != legacy.payload.managedConfiguration.asr)
    }

    @Test
    func conflictSelectionIsRequiredAndBoundToBothFreshPreflights() async throws {
        let resolved = M4PreparedLegacyMigration(
            evidence: M4AcceptanceFixtures.fictionalRedactedEvidence,
            payload: M4AcceptanceFixtures.fictionalOfflineMigrationPayload,
            resolvedASRConfigurationSource: .currentApp
        )
        let source = M4EPreparedSource(
            prepared: [resolved, resolved],
            previewASRConflict: .currentAppAndLegacyEnvironment
        )
        let builder = M4EStoreBuilder(store: M4EFictionalStore())
        let entry = M4ExplicitLegacyMigrationEntry(source: source, builder: builder)
        let preview = try await entry.discover()
        let categories = preview.discovery.detectedCategories
        let targets = M4MigrationOwnedTargetPolicy.requiredTargets(for: categories)

        await #expect(throws: M4LiveMigrationEntryError.confirmationMismatch) {
            _ = try await entry.migrate(
                preview: preview,
                confirmation: M4ExplicitLegacyMigrationConfirmation(
                    confirmedCategories: categories,
                    ownedTargets: targets
                )
            )
        }
        #expect(await source.readCount == 0)

        let receipt = try await entry.migrate(
            preview: preview,
            confirmation: M4ExplicitLegacyMigrationConfirmation(
                confirmedCategories: categories,
                ownedTargets: targets,
                asrConfigurationSource: .currentApp
            )
        )

        #expect(receipt.configurationCommitted)
        #expect(await source.requestedASRSources == [.currentApp, .currentApp])
        #expect(await builder.creationCount == 1)
    }

    @Test
    func changedResolvedASRSourceOnSecondPreflightFailsBeforeFactory() async throws {
        let current = M4PreparedLegacyMigration(
            evidence: M4AcceptanceFixtures.fictionalRedactedEvidence,
            payload: M4AcceptanceFixtures.fictionalOfflineMigrationPayload,
            resolvedASRConfigurationSource: .currentApp
        )
        let changed = M4PreparedLegacyMigration(
            evidence: M4AcceptanceFixtures.fictionalRedactedEvidence,
            payload: M4AcceptanceFixtures.fictionalOfflineMigrationPayload,
            resolvedASRConfigurationSource: .legacyEnvironment
        )
        let source = M4EPreparedSource(
            prepared: [current, changed],
            previewASRConflict: .currentAppAndLegacyEnvironment
        )
        let store = M4EFictionalStore()
        let builder = M4EStoreBuilder(store: store)
        let entry = M4ExplicitLegacyMigrationEntry(source: source, builder: builder)
        let preview = try await entry.discover()
        let categories = preview.discovery.detectedCategories
        let confirmation = M4ExplicitLegacyMigrationConfirmation(
            confirmedCategories: categories,
            ownedTargets: M4MigrationOwnedTargetPolicy.requiredTargets(for: categories),
            asrConfigurationSource: .currentApp
        )

        await #expect(throws: M4MigrationTransactionError.inspectionFailed) {
            _ = try await entry.migrate(preview: preview, confirmation: confirmation)
        }

        #expect(await source.requestedASRSources == [.currentApp, .currentApp])
        #expect(await builder.creationCount == 0)
        #expect(await store.operations.isEmpty)
    }

    @Test
    func explicitEntryBuildsTransactionOnlyAfterFreshDoublePreflight() async throws {
        let events = M4EEventRecorder()
        let source = M4EPreparedSource(
            prepared: [M4EFixtures.prepared, M4EFixtures.prepared],
            events: events
        )
        let store = M4EFictionalStore(events: events)
        let builder = M4EStoreBuilder(store: store, events: events)
        let entry = M4ExplicitLegacyMigrationEntry(source: source, builder: builder)
        let preview = try await entry.discover()
        let categories = preview.discovery.detectedCategories
        let confirmation = M4ExplicitLegacyMigrationConfirmation(
            confirmedCategories: categories,
            ownedTargets: M4MigrationOwnedTargetPolicy.requiredTargets(for: categories)
        )

        let receipt = try await entry.migrate(preview: preview, confirmation: confirmation)

        #expect(await source.previewCount == 1)
        #expect(await source.readCount == 2)
        #expect(await builder.creationCount == 1)
        #expect(await events.values == [
            "preview", "read-1", "read-2", "factory",
            "prepare", "stage-credentials", "stage-configuration", "preserve-paste",
            "validate", "commit", "retain-fallback",
        ])
        #expect(receipt.configurationCommitted)
        #expect(receipt.legacyFallbackRetained)
        #expect(!receipt.runtimeRestarted)
        #expect(!receipt.runtimeActivationAuthorized)
        #expect(receipt.runtimeActivationRequired)
    }

    @Test
    func changedSecondPreflightPreventsFactoryAndEveryTransactionOperation() async throws {
        let changed = M4PreparedLegacyMigration(
            evidence: M4RedactedLegacyEvidence(
                detectedCategories: M4AcceptanceFixtures.fictionalRedactedEvidence.detectedCategories,
                legacyFileExists: true,
                legacyFilePermissionsArePrivate: false,
                runtimeOwnershipIsUnknown: true,
                activeVoiceWorkExists: true
            ),
            payload: M4AcceptanceFixtures.fictionalOfflineMigrationPayload
        )
        let source = M4EPreparedSource(
            prepared: [M4EFixtures.prepared, changed]
        )
        let store = M4EFictionalStore()
        let builder = M4EStoreBuilder(store: store)
        let entry = M4ExplicitLegacyMigrationEntry(source: source, builder: builder)
        let preview = try await entry.discover()
        let categories = preview.discovery.detectedCategories
        let confirmation = M4ExplicitLegacyMigrationConfirmation(
            confirmedCategories: categories,
            ownedTargets: M4MigrationOwnedTargetPolicy.requiredTargets(for: categories)
        )

        await #expect(throws: M4MigrationTransactionError.preflightChangedBeforeMutation) {
            _ = try await entry.migrate(preview: preview, confirmation: confirmation)
        }

        #expect(await source.previewCount == 1)
        #expect(await source.readCount == 2)
        #expect(await builder.creationCount == 0)
        #expect(await store.operations.isEmpty)
    }

    @Test
    func incompleteOrExpandedConfirmationFailsBeforeAnotherRead() async throws {
        let source = M4EPreparedSource(prepared: [])
        let builder = M4EStoreBuilder(store: M4EFictionalStore())
        let entry = M4ExplicitLegacyMigrationEntry(source: source, builder: builder)
        let preview = try await entry.discover()
        let invalid = M4ExplicitLegacyMigrationConfirmation(
            confirmedCategories: [.bridgeCredential],
            ownedTargets: Set(M4MigrationOwnedTarget.allCases)
        )

        await #expect(throws: M4LiveMigrationEntryError.confirmationMismatch) {
            _ = try await entry.migrate(preview: preview, confirmation: invalid)
        }

        #expect(await source.previewCount == 1)
        #expect(await source.readCount == 0)
        #expect(await builder.creationCount == 0)
    }

    @Test
    func cloudASRWithoutCredentialFailsClosedDuringRestrictedDiscovery() async {
        let files = M4EFictionalFileReader(snapshots: [
            .legacyEnvironment: M4RestrictedLegacyFileSnapshot(
                source: .legacyEnvironment,
                exists: true,
                data: Data(
                    """
                    VIBE_STICK_ASR_PROVIDER=groq
                    VIBE_STICK_ASR_MODEL=whisper-large-v3-turbo
                    """.utf8
                ),
                permissions: 0o600
            ),
        ])
        let source = M4RestrictedLegacyMigrationSource(
            files: files,
            credentials: M4EFictionalCredentialReader(values: [:]),
            runtime: M4EFictionalRuntimeFactsReader(facts: M4EFixtures.idleRuntime)
        )
        let entry = M4ExplicitLegacyMigrationEntry(
            source: source,
            builder: M4EStoreBuilder(store: M4EFictionalStore())
        )

        await #expect(throws: M4LiveMigrationEntryError.missingRequiredCredential) {
            _ = try await entry.discover()
        }
    }

    @Test
    func deferredStoreCannotCreateFactoryBeforeTwoInspections() async {
        let source = M4EPreparedSource(prepared: [M4EFixtures.prepared])
        let session = M4PreparedLegacyMigrationSession(source: source)
        let builder = M4EStoreBuilder(store: M4EFictionalStore())
        let deferred = M4DeferredLiveMigrationTransactionStore(
            session: session,
            builder: builder
        )

        await #expect(
            throws: M4LiveMigrationEntryError.doublePreflightNotCompleted
        ) {
            try await deferred.preparePrivateRollback(
                for: M4AcceptanceFixtures.fictionalLegacyDiscovery.detectedCategories
                    .sorted { $0.rawValue < $1.rawValue }
            )
        }

        #expect(await builder.creationCount == 0)
    }
}

private enum M4EFixtures {
    static let prepared = M4PreparedLegacyMigration(
        evidence: M4AcceptanceFixtures.fictionalRedactedEvidence,
        payload: M4AcceptanceFixtures.fictionalOfflineMigrationPayload
    )

    static let idleRuntime = M4LegacyRuntimeFacts(
        runtimeComponentsInstalled: false,
        runtimeOwnershipIsUnknown: false,
        activeVoiceWorkExists: false,
        pasteIdentity: nil,
        accessibilityPermissionGranted: false,
        soundEnabled: nil
    )
}

private func m4EConflictingRestrictedSource() throws -> (
    M4RestrictedLegacyMigrationSource,
    M4EFictionalCredentialReader
) {
    var appConfiguration = AppConfiguration.standard
    appConfiguration.asr = .preset(.siliconFlow)
    let files = M4EFictionalFileReader(snapshots: [
        .legacyEnvironment: M4RestrictedLegacyFileSnapshot(
            source: .legacyEnvironment,
            exists: true,
            data: Data(
                """
                VIBE_STICK_ASR_PROVIDER=groq
                VIBE_STICK_ASR_BASE_URL=https://api.groq.com/openai/v1
                VIBE_STICK_ASR_MODEL=whisper-large-v3-turbo
                VIBE_STICK_ASR_LANGUAGE=zh
                """.utf8
            ),
            permissions: 0o600
        ),
        .appPreferences: M4RestrictedLegacyFileSnapshot(
            source: .appPreferences,
            exists: true,
            data: try JSONEncoder().encode(appConfiguration),
            permissions: 0o600
        ),
        .recordingState: M4RestrictedLegacyFileSnapshot(
            source: .recordingState,
            exists: true,
            data: Data("{\"status\":\"idle\"}".utf8),
            permissions: 0o600
        ),
    ])
    let credentials = M4EFictionalCredentialReader(values: [
        .asrAPIKey: Data("fixture-conflict-asr-secret".utf8),
    ])
    return (
        M4RestrictedLegacyMigrationSource(
            files: files,
            credentials: credentials,
            runtime: M4EFictionalRuntimeFactsReader(facts: M4EFixtures.idleRuntime)
        ),
        credentials
    )
}

private actor M4EFictionalFileReader: M4RestrictedLegacyFileReading {
    private let snapshots: [M4RestrictedLegacyFile: M4RestrictedLegacyFileSnapshot]

    init(snapshots: [M4RestrictedLegacyFile: M4RestrictedLegacyFileSnapshot]) {
        self.snapshots = snapshots
    }

    func read(_ source: M4RestrictedLegacyFile) -> M4RestrictedLegacyFileSnapshot {
        snapshots[source] ?? .missing(source)
    }
}

private actor M4EFictionalCredentialReader: M4RestrictedLegacyCredentialReading {
    private let values: [M4CredentialPurpose: Data]
    private(set) var containsCount = 0
    private(set) var readCount = 0

    init(values: [M4CredentialPurpose: Data]) {
        self.values = values
    }

    func containsCredential(for purpose: M4CredentialPurpose) -> Bool {
        containsCount += 1
        return values[purpose] != nil
    }

    func readCredential(for purpose: M4CredentialPurpose) -> Data? {
        readCount += 1
        return values[purpose]
    }
}

private actor M4EFictionalRuntimeFactsReader: M4LegacyRuntimeFactsReading {
    private let facts: M4LegacyRuntimeFacts

    init(facts: M4LegacyRuntimeFacts) {
        self.facts = facts
    }

    func readRuntimeFacts() -> M4LegacyRuntimeFacts {
        facts
    }
}

private actor M4EPreparedSource: M4ExplicitLegacyMigrationReading {
    private var prepared: [M4PreparedLegacyMigration]
    private let previewEvidence: M4RedactedLegacyEvidence
    private let previewASRConflict: M4RedactedASRConfigurationConflict?
    private let events: M4EEventRecorder?
    private(set) var previewCount = 0
    private(set) var readCount = 0
    private(set) var requestedASRSources: [M4ASRConfigurationSource?] = []

    init(
        prepared: [M4PreparedLegacyMigration],
        previewEvidence: M4RedactedLegacyEvidence = M4AcceptanceFixtures.fictionalRedactedEvidence,
        previewASRConflict: M4RedactedASRConfigurationConflict? = nil,
        events: M4EEventRecorder? = nil
    ) {
        self.prepared = prepared
        self.previewEvidence = previewEvidence
        self.previewASRConflict = previewASRConflict
        self.events = events
    }

    func readRedactedLegacyDiscovery() async -> M4RedactedLegacyMigrationDiscovery {
        previewCount += 1
        await events?.record("preview")
        return M4RedactedLegacyMigrationDiscovery(
            evidence: previewEvidence,
            asrConfigurationConflict: previewASRConflict
        )
    }

    func readPreparedLegacyMigration(
        asrConfigurationSource: M4ASRConfigurationSource?
    ) async throws -> M4PreparedLegacyMigration {
        readCount += 1
        requestedASRSources.append(asrConfigurationSource)
        await events?.record("read-\(readCount)")
        guard !prepared.isEmpty else { throw M4EFictionalFailure.exhausted }
        return prepared.removeFirst()
    }
}

private actor M4EStoreBuilder: M4LiveMigrationTransactionStoreBuilding {
    private let store: M4EFictionalStore
    private let events: M4EEventRecorder?
    private(set) var creationCount = 0

    init(store: M4EFictionalStore, events: M4EEventRecorder? = nil) {
        self.store = store
        self.events = events
    }

    func makeStore(
        payload: M4OfflineMigrationPayload
    ) async throws -> any M4LegacyMigrationTransactionStoring {
        _ = try payload.validated()
        creationCount += 1
        await events?.record("factory")
        return store
    }
}

private actor M4EFictionalStore: M4LegacyMigrationTransactionStoring {
    private let events: M4EEventRecorder?
    private(set) var operations: [M4MigrationTransactionOperation] = []

    init(events: M4EEventRecorder? = nil) {
        self.events = events
    }

    func preparePrivateRollback(for categories: [M4LegacyConfigurationCategory]) async {
        operations.append(.preparePrivateRollback)
        await events?.record("prepare")
    }

    func stageVersionedKeychainItems(for categories: [M4LegacyConfigurationCategory]) async {
        operations.append(.stageVersionedKeychainItems)
        await events?.record("stage-credentials")
    }

    func stageConfigurationFiles(for categories: [M4LegacyConfigurationCategory]) async {
        operations.append(.stageConfigurationFiles)
        await events?.record("stage-configuration")
    }

    func preservePasteIdentity() async {
        operations.append(.preservePasteIdentity)
        await events?.record("preserve-paste")
    }

    func validateStagedState() async -> M4StagedMigrationValidation {
        operations.append(.validateStagedState)
        await events?.record("validate")
        return M4AcceptanceFixtures.fictionalSafeStagedMigration
    }

    func atomicallyCommitConfiguration() async {
        operations.append(.atomicallyCommitConfiguration)
        await events?.record("commit")
    }

    func retainLegacyFallback() async {
        operations.append(.retainLegacyFallback)
        await events?.record("retain-fallback")
    }

    func restorePreviousStateAndDiscardStaging() async {
        operations.append(.restorePreviousState)
        await events?.record("restore")
    }
}

private actor M4EEventRecorder {
    private(set) var values: [String] = []

    func record(_ value: String) {
        values.append(value)
    }
}

private enum M4EFictionalFailure: Error {
    case exhausted
}
