import Foundation

// M4-5A keeps these models deliberately pure. They describe what later migration,
// diagnostic, and clean-machine workflows may do, but never inspect or mutate the
// current Mac, Keychain, runtime, network, or device.

enum M4LegacyConfigurationCategory: String, CaseIterable, Codable, Hashable, Sendable {
    case runtimeComponents = "runtime-components"
    case bridgeCredential = "bridge-credential"
    case asrCredential = "asr-credential"
    case asrConfiguration = "asr-configuration"
    case agentProvider = "agent-provider"
    case projectPresentation = "project-presentation"
    case voiceDelivery = "voice-delivery"
    case soundPreference = "sound-preference"
    case accessibilityPermission = "accessibility-permission"

    var containsSecret: Bool {
        self == .bridgeCredential || self == .asrCredential
    }

    var requiresConfigurationWrite: Bool {
        switch self {
        case .asrConfiguration, .agentProvider, .projectPresentation,
             .voiceDelivery, .soundPreference:
            true
        case .runtimeComponents, .bridgeCredential, .asrCredential,
             .accessibilityPermission:
            false
        }
    }
}

struct M4LegacyDiscovery: Equatable, Sendable {
    let detectedCategories: Set<M4LegacyConfigurationCategory>
    let legacyFileExists: Bool
    let legacyFilePermissionsArePrivate: Bool
    let unknownRuntimeOwnerDetected: Bool
    let activeVoiceWorkDetected: Bool
}

enum M4LegacyMigrationBlocker: String, Equatable, Sendable {
    case unknownRuntimeOwner = "unknown-runtime-owner"
    case activeVoiceWork = "active-voice-work"
}

enum M4LegacyMigrationStep: String, Equatable, Sendable {
    case presentRedactedSummary = "present-redacted-summary"
    case requestImportConfirmation = "request-import-confirmation"
    case createPrivateRollbackSnapshot = "create-private-rollback-snapshot"
    case stageKeychainItems = "stage-keychain-items"
    case stageConfigurationFiles = "stage-configuration-files"
    case preservePasteIdentity = "preserve-paste-identity"
    case validateStagedState = "validate-staged-state"
    case atomicallyCommit = "atomically-commit"
    case retainLegacyFallback = "retain-legacy-fallback"
    case requestRuntimeActivationConfirmation = "request-runtime-activation-confirmation"
    case recheckAccessibility = "recheck-accessibility"
}

struct M4LegacyMigrationPlan: Equatable, Sendable {
    static let schemaVersion = 1

    let categories: [M4LegacyConfigurationCategory]
    let blockers: [M4LegacyMigrationBlocker]
    let steps: [M4LegacyMigrationStep]
    let requiresExplicitConfirmation: Bool
    let preservesLegacyFiles: Bool
    let mayDeleteLegacyFiles: Bool
    let mayRestartRuntime: Bool

    var canOfferImport: Bool {
        !categories.isEmpty && blockers.isEmpty
    }
}

enum M4LegacyMigrationPlanner {
    static func make(from discovery: M4LegacyDiscovery) -> M4LegacyMigrationPlan {
        let categories = discovery.detectedCategories.sorted { $0.rawValue < $1.rawValue }
        var blockers: [M4LegacyMigrationBlocker] = []
        if discovery.unknownRuntimeOwnerDetected {
            blockers.append(.unknownRuntimeOwner)
        }
        if discovery.activeVoiceWorkDetected {
            blockers.append(.activeVoiceWork)
        }

        var steps: [M4LegacyMigrationStep] = [.presentRedactedSummary]
        if !categories.isEmpty, blockers.isEmpty {
            steps.append(contentsOf: [
                .requestImportConfirmation,
                .createPrivateRollbackSnapshot,
            ])
            if categories.contains(where: \.containsSecret) {
                steps.append(.stageKeychainItems)
            }
            if categories.contains(where: \.requiresConfigurationWrite) {
                steps.append(.stageConfigurationFiles)
            }
            if categories.contains(.runtimeComponents) {
                steps.append(.preservePasteIdentity)
            }
            steps.append(contentsOf: [
                .validateStagedState,
                .atomicallyCommit,
                .retainLegacyFallback,
                .requestRuntimeActivationConfirmation,
            ])
            if categories.contains(.accessibilityPermission) {
                steps.append(.recheckAccessibility)
            }
        }

        return M4LegacyMigrationPlan(
            categories: categories,
            blockers: blockers,
            steps: steps,
            requiresExplicitConfirmation: !categories.isEmpty && blockers.isEmpty,
            preservesLegacyFiles: true,
            mayDeleteLegacyFiles: false,
            mayRestartRuntime: false
        )
    }
}

enum M4DiagnosticSourceKind: String, Codable, Equatable, Sendable {
    case appMetadata = "app-metadata"
    case operatingSystemMetadata = "operating-system-metadata"
    case componentHealth = "component-health"
    case signatureStatus = "signature-status"
    case launchAgentStatus = "launch-agent-status"
    case bridgeHealth = "bridge-health"
    case migrationReceiptSummary = "migration-receipt-summary"
    case runtimeInstallReceiptSummary = "runtime-install-receipt-summary"
    case redactedLogExcerpt = "redacted-log-excerpt"
    case rawEnvironment = "raw-environment"
    case rawPreferences = "raw-preferences"
    case rawDeviceRegistry = "raw-device-registry"
    case rawRecording = "raw-recording"
    case rawLog = "raw-log"
    case keychainValue = "keychain-value"
    case firmwareBackup = "firmware-backup"
    case firmwareTransaction = "firmware-transaction"
}

struct M4DiagnosticPlannedEntry: Equatable, Sendable {
    let relativePath: String
    let source: M4DiagnosticSourceKind
}

struct M4DiagnosticBundlePlan: Equatable, Sendable {
    static let schemaVersion = 1

    let entries: [M4DiagnosticPlannedEntry]
    let requiresExplicitExportConfirmation: Bool
    let uploadsAutomatically: Bool
    let includesRawLogs: Bool
}

enum M4DiagnosticPolicy {
    static let forbiddenSourceNames: Set<String> = [
        ".env",
        "config-v1.json",
        "devices-v1.json",
        "device-config-v1.json",
        "bridge-identity-v1.json",
        "recording.json",
        "bridge.log",
        "bridge.err.log",
        "hud.log",
        "hud.err.log",
        "flash-8MiB.bin",
        "prewrite-nvs-v1.bin",
        "latest-v1.json",
    ]

    static func permits(_ source: M4DiagnosticSourceKind) -> Bool {
        switch source {
        case .appMetadata, .operatingSystemMetadata, .componentHealth,
             .signatureStatus, .launchAgentStatus, .bridgeHealth,
             .migrationReceiptSummary, .runtimeInstallReceiptSummary,
             .redactedLogExcerpt:
            true
        case .rawEnvironment, .rawPreferences, .rawDeviceRegistry,
             .rawRecording, .rawLog, .keychainValue, .firmwareBackup,
             .firmwareTransaction:
            false
        }
    }

    static func isSafeRelativePath(_ path: String) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.contains("\\"),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return false
        }
        return true
    }

    static func makePlan(includeRedactedLogs: Bool) -> M4DiagnosticBundlePlan {
        var entries = [
            M4DiagnosticPlannedEntry(relativePath: "manifest-v1.json", source: .appMetadata),
            M4DiagnosticPlannedEntry(relativePath: "summary-v1.json", source: .componentHealth),
            M4DiagnosticPlannedEntry(relativePath: "system-v1.json", source: .operatingSystemMetadata),
            M4DiagnosticPlannedEntry(relativePath: "runtime-v1.json", source: .launchAgentStatus),
        ]
        if includeRedactedLogs {
            entries.append(contentsOf: [
                M4DiagnosticPlannedEntry(
                    relativePath: "logs/bridge-redacted.txt",
                    source: .redactedLogExcerpt
                ),
                M4DiagnosticPlannedEntry(
                    relativePath: "logs/hud-redacted.txt",
                    source: .redactedLogExcerpt
                ),
            ])
        }
        return M4DiagnosticBundlePlan(
            entries: entries,
            requiresExplicitExportConfirmation: true,
            uploadsAutomatically: false,
            includesRawLogs: false
        )
    }
}

struct M4CleanMachineProfile: Equatable, Sendable {
    let hasHomebrew: Bool
    let hasXcode: Bool
    let hasExternalPython: Bool
    let hasESPIDF: Bool
    let bundledRuntimePresent: Bool
    let bundledRuntimeManifestVerified: Bool
    let runtimeUsesBundledInterpreter: Bool

    var representsRequiredBaseline: Bool {
        !hasHomebrew && !hasXcode && !hasExternalPython && !hasESPIDF
    }
}

enum M4CleanMachineBlocker: String, Equatable, Sendable {
    case developerDependencyPresent = "developer-dependency-present"
    case bundledRuntimeMissing = "bundled-runtime-missing"
    case bundledRuntimeUnverified = "bundled-runtime-unverified"
    case externalInterpreterRequired = "external-interpreter-required"
}

enum M4CleanMachineReadinessPlanner {
    static func blockers(for profile: M4CleanMachineProfile) -> [M4CleanMachineBlocker] {
        var blockers: [M4CleanMachineBlocker] = []
        if !profile.representsRequiredBaseline {
            blockers.append(.developerDependencyPresent)
        }
        if !profile.bundledRuntimePresent {
            blockers.append(.bundledRuntimeMissing)
        } else if !profile.bundledRuntimeManifestVerified {
            blockers.append(.bundledRuntimeUnverified)
        }
        if !profile.runtimeUsesBundledInterpreter {
            blockers.append(.externalInterpreterRequired)
        }
        return blockers
    }
}

enum M4AuthorizationGate: String, CaseIterable, Equatable, Sendable {
    case repositoryImplementation = "repository-implementation"
    case localTestAndBuild = "local-test-and-build"
    case liveLegacyInspection = "live-legacy-inspection"
    case liveMigration = "live-migration"
    case runtimeActivation = "runtime-activation"
    case diagnosticExport = "diagnostic-export"
    case mainAppInstallation = "main-app-installation"
    case runtimeInstallation = "runtime-installation"
    case toolDownload = "tool-download"
    case toolPreparation = "tool-preparation"
    case deviceInspection = "device-inspection"
    case deviceBackup = "device-backup"
    case candidateWrite = "candidate-write"
    case candidateReadback = "candidate-readback"
    case pairingProvisioning = "pairing-provisioning"
    case functionalAcceptance = "functional-acceptance"
    case recoveryWrite = "recovery-write"
    case recoveryReadback = "recovery-readback"
    case localCommit = "local-commit"
    case push = "push"
    case tag = "tag"
    case release = "release"

    var impliedAuthorizations: [M4AuthorizationGate] {
        [self]
    }
}
