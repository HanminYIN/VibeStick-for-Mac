import Foundation

enum M4AcceptanceFixtures {
    static let fictionalBridgeSecret = "fixture-bridge-secret-m4-5c"
    static let fictionalASRSecret = "fixture-asr-secret-m4-5c"

    static let fictionalRedactedEvidence = M4RedactedLegacyEvidence(
        detectedCategories: Set(M4LegacyConfigurationCategory.allCases),
        legacyFileExists: true,
        legacyFilePermissionsArePrivate: false,
        runtimeOwnershipIsUnknown: false,
        activeVoiceWorkExists: false
    )

    static let fictionalLegacyDiscovery = M4LegacyDiscovery(
        detectedCategories: [
            .runtimeComponents,
            .bridgeCredential,
            .asrCredential,
            .asrConfiguration,
            .agentProvider,
            .projectPresentation,
            .voiceDelivery,
            .soundPreference,
            .accessibilityPermission,
        ],
        legacyFileExists: true,
        legacyFilePermissionsArePrivate: false,
        unknownRuntimeOwnerDetected: false,
        activeVoiceWorkDetected: false
    )

    static let fictionalBlockedLegacyDiscovery = M4LegacyDiscovery(
        detectedCategories: [.runtimeComponents, .bridgeCredential],
        legacyFileExists: true,
        legacyFilePermissionsArePrivate: true,
        unknownRuntimeOwnerDetected: true,
        activeVoiceWorkDetected: true
    )

    static let fictionalCleanMachineWithoutRuntime = M4CleanMachineProfile(
        hasHomebrew: false,
        hasXcode: false,
        hasExternalPython: false,
        hasESPIDF: false,
        bundledRuntimePresent: false,
        bundledRuntimeManifestVerified: false,
        runtimeUsesBundledInterpreter: false
    )

    static let fictionalReadyCleanMachine = M4CleanMachineProfile(
        hasHomebrew: false,
        hasXcode: false,
        hasExternalPython: false,
        hasESPIDF: false,
        bundledRuntimePresent: true,
        bundledRuntimeManifestVerified: true,
        runtimeUsesBundledInterpreter: true
    )

    static let fictionalMigrationAuthorization = M4LegacyMigrationAuthorization(
        confirmedDiscovery: fictionalLegacyDiscovery,
        confirmedCategories: fictionalLegacyDiscovery.detectedCategories,
        ownedTargets: Set(M4MigrationOwnedTarget.allCases)
    )

    static let fictionalSafeStagedMigration = M4StagedMigrationValidation(
        rollbackDirectoryIsPrivate: true,
        rollbackFilesArePrivate: true,
        secretsUseNewVersionedAccounts: true,
        legacyKeychainItemsAreUntouched: true,
        stagedConfigurationContainsSecrets: false,
        existingPasteIdentityIsPreserved: true
    )

    static var fictionalOfflineMigrationPayload: M4OfflineMigrationPayload {
        fictionalOfflineMigrationPayload(projectName: "Fictional Workspace")
    }

    static func fictionalOfflineMigrationPayload(
        projectName: String
    ) -> M4OfflineMigrationPayload {
        M4OfflineMigrationPayload(
            categories: fictionalLegacyDiscovery.detectedCategories,
            credentialSecrets: [
                .bridgeToken: Data(fictionalBridgeSecret.utf8),
                .asrAPIKey: Data(fictionalASRSecret.utf8),
            ],
            managedConfiguration: M4ManagedRuntimeConfiguration(
                schemaVersion: M4ManagedRuntimeConfiguration.currentSchemaVersion,
                credentialReferences: [
                    .managed(.bridgeToken),
                    .managed(.asrAPIKey),
                ],
                asr: M4ManagedASRConfiguration(
                    provider: "groq",
                    baseURL: "https://api.groq.com/openai/v1",
                    model: "whisper-large-v3-turbo",
                    language: "zh",
                    localCommand: ""
                ),
                agentProvider: "auto",
                projectPresentation: M4ManagedProjectPresentation(
                    projectName: projectName,
                    showProjectName: true
                ),
                voiceDelivery: M4ManagedVoiceDelivery(sendMode: "confirm"),
                soundEnabled: true
            ),
            rollbackArtifacts: [
                M4OfflineRollbackArtifact(
                    fileName: "legacy-environment.fixture",
                    data: Data(
                        "VIBE_STICK_BRIDGE_TOKEN=fixture-legacy-value\n".utf8
                    )
                ),
            ],
            existingPasteIdentity: "io.github.hanminyin.vibestick.paste.fixture"
        )
    }

    static let forbiddenDiagnosticSourceNames = [
        ".env",
        "config-v1.json",
        "devices-v1.json",
        "recording.json",
        "bridge.log",
        "hud.err.log",
        "flash-8MiB.bin",
        "prewrite-nvs-v1.bin",
        "latest-v1.json",
    ]
}
