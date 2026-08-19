import Foundation

// M4-5C remains an offline-only adapter. Its filesystem root must be inside the
// process temporary directory and its credential vault is always injected. It
// cannot discover the current user's support directory, open Keychain, inspect
// processes, activate a runtime, or control a service.

enum M4CredentialPurpose: String, CaseIterable, Codable, Hashable, Sendable {
    case bridgeToken = "bridge-token"
    case asrAPIKey = "asr-api-key"

    var legacyCategory: M4LegacyConfigurationCategory {
        switch self {
        case .bridgeToken: .bridgeCredential
        case .asrAPIKey: .asrCredential
        }
    }
}

struct M4VersionedCredentialReference: Codable, Equatable, Hashable, Sendable {
    static let currentSchemaVersion = 1
    static let storage = "macos-keychain"
    static let service = "io.github.hanminyin.vibestick"

    let schemaVersion: Int
    let purpose: M4CredentialPurpose
    let storage: String
    let service: String
    let account: String

    static func managed(_ purpose: M4CredentialPurpose) -> Self {
        M4VersionedCredentialReference(
            schemaVersion: currentSchemaVersion,
            purpose: purpose,
            storage: storage,
            service: service,
            account: purpose == .bridgeToken ? "bridge-token-v1" : "asr-api-key-v1"
        )
    }

    var isManagedVersion: Bool {
        self == Self.managed(purpose)
    }
}

struct M4ManagedASRConfiguration: Codable, Equatable, Sendable {
    let provider: String
    let baseURL: String
    let model: String
    let language: String
    let localCommand: String

    var requiresCredential: Bool {
        provider != "local-command"
    }
}

struct M4ManagedProjectPresentation: Codable, Equatable, Sendable {
    let projectName: String
    let showProjectName: Bool
}

struct M4ManagedVoiceDelivery: Codable, Equatable, Sendable {
    let sendMode: String
}

struct M4ManagedRuntimeConfiguration: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let credentialReferences: [M4VersionedCredentialReference]
    let asr: M4ManagedASRConfiguration?
    let agentProvider: String?
    let projectPresentation: M4ManagedProjectPresentation?
    let voiceDelivery: M4ManagedVoiceDelivery?
    let soundEnabled: Bool?

    func validated() throws -> Self {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw M4OfflineMigrationAdapterError.unsupportedConfigurationSchema
        }
        guard credentialReferences.allSatisfy(\.isManagedVersion) else {
            throw M4OfflineMigrationAdapterError.invalidCredentialReference
        }
        let purposes = credentialReferences.map(\.purpose)
        guard Set(purposes).count == purposes.count else {
            throw M4OfflineMigrationAdapterError.duplicateCredentialReference
        }
        if let asr {
            let supportedProviders = ["groq", "siliconflow", "openai-compatible", "local-command"]
            guard supportedProviders.contains(asr.provider),
                  !asr.language.isEmpty,
                  asr.language.count <= 12 else {
                throw M4OfflineMigrationAdapterError.invalidManagedConfiguration
            }
            if asr.provider == "local-command" {
                guard !asr.localCommand.isEmpty else {
                    throw M4OfflineMigrationAdapterError.invalidManagedConfiguration
                }
            } else {
                guard !asr.baseURL.isEmpty, !asr.model.isEmpty else {
                    throw M4OfflineMigrationAdapterError.invalidManagedConfiguration
                }
            }
        }
        if let agentProvider, !["codex", "claude", "auto"].contains(agentProvider) {
            throw M4OfflineMigrationAdapterError.invalidManagedConfiguration
        }
        if let voiceDelivery,
           !["paste_only", "confirm", "auto_send"].contains(voiceDelivery.sendMode) {
            throw M4OfflineMigrationAdapterError.invalidManagedConfiguration
        }
        return self
    }

    func credentialReference(
        for purpose: M4CredentialPurpose
    ) -> M4VersionedCredentialReference? {
        credentialReferences.first { $0.purpose == purpose }
    }
}

struct M4OfflineRollbackArtifact: Equatable, Sendable {
    let fileName: String
    let data: Data

    var hasSafeFileName: Bool {
        !fileName.isEmpty
            && fileName != "."
            && fileName != ".."
            && !fileName.contains("/")
            && !fileName.contains(":")
    }
}

struct M4OfflineMigrationPayload: Equatable, Sendable {
    let categories: Set<M4LegacyConfigurationCategory>
    let credentialSecrets: [M4CredentialPurpose: Data]
    let managedConfiguration: M4ManagedRuntimeConfiguration
    let rollbackArtifacts: [M4OfflineRollbackArtifact]
    let existingPasteIdentity: String?

    func validated() throws -> Self {
        _ = try managedConfiguration.validated()
        guard !categories.isEmpty,
              rollbackArtifacts.allSatisfy(\.hasSafeFileName),
              Set(rollbackArtifacts.map(\.fileName)).count == rollbackArtifacts.count else {
            throw M4OfflineMigrationAdapterError.invalidOfflinePayload
        }

        let expectedPurposes = Set(
            M4CredentialPurpose.allCases.filter { categories.contains($0.legacyCategory) }
        )
        guard Set(credentialSecrets.keys) == expectedPurposes,
              credentialSecrets.values.allSatisfy({ !$0.isEmpty }),
              Set(managedConfiguration.credentialReferences.map(\.purpose)) == expectedPurposes else {
            throw M4OfflineMigrationAdapterError.credentialCategoryMismatch
        }

        guard (managedConfiguration.asr != nil) == categories.contains(.asrConfiguration),
              (managedConfiguration.agentProvider != nil) == categories.contains(.agentProvider),
              (managedConfiguration.projectPresentation != nil) == categories.contains(.projectPresentation),
              (managedConfiguration.voiceDelivery != nil) == categories.contains(.voiceDelivery),
              (managedConfiguration.soundEnabled != nil) == categories.contains(.soundPreference) else {
            throw M4OfflineMigrationAdapterError.configurationCategoryMismatch
        }

        if managedConfiguration.asr?.requiresCredential == true,
           categories.contains(.asrConfiguration),
           !expectedPurposes.contains(.asrAPIKey) {
            throw M4OfflineMigrationAdapterError.credentialCategoryMismatch
        }

        if categories.contains(.runtimeComponents) {
            guard let existingPasteIdentity, !existingPasteIdentity.isEmpty else {
                throw M4OfflineMigrationAdapterError.missingPasteIdentity
            }
        } else if existingPasteIdentity != nil {
            throw M4OfflineMigrationAdapterError.configurationCategoryMismatch
        }
        return self
    }
}

protocol M4OfflineCredentialVault: Sendable {
    func stage(_ secret: Data, for reference: M4VersionedCredentialReference) async throws
    func read(_ reference: M4VersionedCredentialReference) async throws -> Data?
    func contains(_ reference: M4VersionedCredentialReference) async throws -> Bool
    func discard(_ reference: M4VersionedCredentialReference) async throws
    func legacyAccountsRemainUntouched() async -> Bool
}

struct M4ResolvedBridgeRuntimeConfiguration: Equatable, Sendable {
    let bridgeToken: String?
    let asrAPIKey: String?
    let managedConfiguration: M4ManagedRuntimeConfiguration
}

struct M4BridgeRuntimeConfigurationResolver: Sendable {
    private let credentialVault: any M4OfflineCredentialVault

    init(credentialVault: any M4OfflineCredentialVault) {
        self.credentialVault = credentialVault
    }

    func resolve(_ data: Data) async throws -> M4ResolvedBridgeRuntimeConfiguration {
        let decoded: M4ManagedRuntimeConfiguration
        do {
            decoded = try JSONDecoder().decode(M4ManagedRuntimeConfiguration.self, from: data)
        } catch {
            throw M4OfflineMigrationAdapterError.unreadableManagedConfiguration
        }
        let configuration = try decoded.validated()

        let bridgeToken = try await resolvedString(for: .bridgeToken, in: configuration)
        let asrAPIKey: String?
        if configuration.asr?.requiresCredential == true {
            asrAPIKey = try await resolvedString(for: .asrAPIKey, in: configuration)
        } else {
            asrAPIKey = nil
        }
        return M4ResolvedBridgeRuntimeConfiguration(
            bridgeToken: bridgeToken,
            asrAPIKey: asrAPIKey,
            managedConfiguration: configuration
        )
    }

    private func resolvedString(
        for purpose: M4CredentialPurpose,
        in configuration: M4ManagedRuntimeConfiguration
    ) async throws -> String? {
        guard let reference = configuration.credentialReference(for: purpose) else { return nil }
        guard reference.isManagedVersion else {
            throw M4OfflineMigrationAdapterError.invalidCredentialReference
        }
        guard let data = try await credentialVault.read(reference),
              let value = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            throw M4OfflineMigrationAdapterError.missingCredential
        }
        return value
    }
}

struct M4OfflineMigrationLocations: Equatable, Sendable {
    let sandboxRoot: URL
    let transactionRoot: URL
    let rollbackDirectory: URL
    let stagingDirectory: URL
    let stagedConfiguration: URL
    let committedConfiguration: URL
    let fallbackMarker: URL
}

enum M4OfflineMigrationAdapterError: Error, Equatable, Sendable {
    case rootOutsideTemporaryDirectory
    case unsupportedConfigurationSchema
    case invalidCredentialReference
    case duplicateCredentialReference
    case invalidManagedConfiguration
    case invalidOfflinePayload
    case transactionRootAlreadyExists
    case credentialCategoryMismatch
    case configurationCategoryMismatch
    case missingPasteIdentity
    case invalidOperationOrder
    case categoryRequestMismatch
    case unreadableManagedConfiguration
    case missingCredential
    case secretEnteredManagedConfiguration
}

actor M4OfflineMigrationTransactionStore: M4LegacyMigrationTransactionStoring {
    nonisolated let locations: M4OfflineMigrationLocations

    private let fileManager: FileManager
    private let payload: M4OfflineMigrationPayload
    private let credentialVault: any M4OfflineCredentialVault
    private let encoder: JSONEncoder
    private var prepared = false
    private var stagedCredentialReferences: [M4VersionedCredentialReference] = []
    private var preservedPasteIdentity: String?
    private var stagedValidationAccepted = false
    private var configurationCommitted = false
    private var previousConfigurationExisted = false

    private var previousConfigurationSnapshot: URL {
        locations.rollbackDirectory.appendingPathComponent("previous-managed-runtime-v1.json")
    }

    init(
        sandboxRoot: URL,
        payload: M4OfflineMigrationPayload,
        credentialVault: any M4OfflineCredentialVault,
        fileManager: FileManager = .default
    ) throws {
        guard Self.isInsideTemporaryDirectory(sandboxRoot, fileManager: fileManager) else {
            throw M4OfflineMigrationAdapterError.rootOutsideTemporaryDirectory
        }
        self.fileManager = fileManager
        self.payload = try payload.validated()
        self.credentialVault = credentialVault
        let transactionRoot = sandboxRoot.appendingPathComponent(
            "m4-5c-offline-transaction-v1",
            isDirectory: true
        )
        let rollbackDirectory = transactionRoot.appendingPathComponent("rollback", isDirectory: true)
        let stagingDirectory = transactionRoot.appendingPathComponent("staging", isDirectory: true)
        self.locations = M4OfflineMigrationLocations(
            sandboxRoot: sandboxRoot,
            transactionRoot: transactionRoot,
            rollbackDirectory: rollbackDirectory,
            stagingDirectory: stagingDirectory,
            stagedConfiguration: stagingDirectory.appendingPathComponent("managed-runtime-v1.json"),
            committedConfiguration: sandboxRoot.appendingPathComponent("managed-runtime-v1.json"),
            fallbackMarker: rollbackDirectory.appendingPathComponent("legacy-fallback-retained-v1.json")
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
    }

    func preparePrivateRollback(
        for categories: [M4LegacyConfigurationCategory]
    ) throws {
        try requireRequestedCategories(categories, expected: payload.categories)
        guard !prepared else { throw M4OfflineMigrationAdapterError.invalidOperationOrder }
        guard !fileManager.fileExists(atPath: locations.transactionRoot.path) else {
            throw M4OfflineMigrationAdapterError.transactionRootAlreadyExists
        }

        try createPrivateDirectory(locations.sandboxRoot)
        try createPrivateDirectory(locations.transactionRoot)
        try createPrivateDirectory(locations.rollbackDirectory)

        let manifest = M4OfflineRollbackManifest(
            schemaVersion: 1,
            categories: categories,
            artifactNames: payload.rollbackArtifacts.map(\.fileName).sorted()
        )
        try writePrivate(try encoder.encode(manifest), to: locations.rollbackDirectory
            .appendingPathComponent("rollback-manifest-v1.json"))
        for artifact in payload.rollbackArtifacts {
            try writePrivate(
                artifact.data,
                to: locations.rollbackDirectory.appendingPathComponent(artifact.fileName)
            )
        }

        previousConfigurationExisted = fileManager.fileExists(
            atPath: locations.committedConfiguration.path
        )
        if previousConfigurationExisted {
            let previous = try Data(contentsOf: locations.committedConfiguration)
            try writePrivate(previous, to: previousConfigurationSnapshot)
        }
        prepared = true
    }

    func stageVersionedKeychainItems(
        for categories: [M4LegacyConfigurationCategory]
    ) async throws {
        guard prepared, stagedCredentialReferences.isEmpty else {
            throw M4OfflineMigrationAdapterError.invalidOperationOrder
        }
        let expected = Set(payload.credentialSecrets.keys.map(\.legacyCategory))
        try requireRequestedCategories(categories, expected: expected)

        for purpose in M4CredentialPurpose.allCases where payload.credentialSecrets[purpose] != nil {
            guard let secret = payload.credentialSecrets[purpose],
                  let reference = payload.managedConfiguration.credentialReference(for: purpose),
                  reference.isManagedVersion else {
                throw M4OfflineMigrationAdapterError.invalidCredentialReference
            }
            try await credentialVault.stage(secret, for: reference)
            stagedCredentialReferences.append(reference)
        }
        if !payload.categories.contains(where: \.requiresConfigurationWrite) {
            try stageManagedConfigurationIfNeeded()
        }
    }

    func stageConfigurationFiles(
        for categories: [M4LegacyConfigurationCategory]
    ) throws {
        guard prepared else { throw M4OfflineMigrationAdapterError.invalidOperationOrder }
        let expected = Set(payload.categories.filter(\.requiresConfigurationWrite))
        try requireRequestedCategories(categories, expected: expected)
        try stageManagedConfigurationIfNeeded()
    }

    func preservePasteIdentity() throws {
        guard prepared,
              payload.categories.contains(.runtimeComponents),
              let identity = payload.existingPasteIdentity else {
            throw M4OfflineMigrationAdapterError.invalidOperationOrder
        }
        preservedPasteIdentity = identity
    }

    func validateStagedState() async throws -> M4StagedMigrationValidation {
        guard prepared else { throw M4OfflineMigrationAdapterError.invalidOperationOrder }
        let rollbackFiles = try fileManager.contentsOfDirectory(
            at: locations.rollbackDirectory,
            includingPropertiesForKeys: nil
        )
        let references = payload.managedConfiguration.credentialReferences
        var allCredentialsExist = true
        for reference in references {
            if try await credentialVault.contains(reference) == false {
                allCredentialsExist = false
            }
        }
        let stagedData = try? Data(contentsOf: locations.stagedConfiguration)
        let validation = M4StagedMigrationValidation(
            rollbackDirectoryIsPrivate: permissions(at: locations.rollbackDirectory) == 0o700,
            rollbackFilesArePrivate: rollbackFiles.allSatisfy { permissions(at: $0) == 0o600 },
            secretsUseNewVersionedAccounts: references.allSatisfy(\.isManagedVersion)
                && allCredentialsExist,
            legacyKeychainItemsAreUntouched: await credentialVault.legacyAccountsRemainUntouched(),
            stagedConfigurationContainsSecrets: stagedData.map(containsAnySecret) ?? false,
            existingPasteIdentityIsPreserved: !payload.categories.contains(.runtimeComponents)
                || preservedPasteIdentity == payload.existingPasteIdentity
        )
        stagedValidationAccepted = validation.accepts(categories: payload.categories)
        return validation
    }

    func atomicallyCommitConfiguration() throws {
        guard stagedValidationAccepted else {
            throw M4OfflineMigrationAdapterError.invalidOperationOrder
        }
        guard fileManager.fileExists(atPath: locations.stagedConfiguration.path) else {
            configurationCommitted = true
            return
        }
        let data = try Data(contentsOf: locations.stagedConfiguration)
        try writePrivate(data, to: locations.committedConfiguration, atomically: true)
        try fileManager.removeItem(at: locations.stagedConfiguration)
        configurationCommitted = true
    }

    func retainLegacyFallback() throws {
        guard configurationCommitted else {
            throw M4OfflineMigrationAdapterError.invalidOperationOrder
        }
        let marker = M4OfflineFallbackMarker(
            schemaVersion: 1,
            categories: payload.categories.sorted { $0.rawValue < $1.rawValue },
            legacyItemsDeleted: false,
            runtimeActivated: false
        )
        try writePrivate(try encoder.encode(marker), to: locations.fallbackMarker)
    }

    func restorePreviousStateAndDiscardStaging() async throws {
        if configurationCommitted {
            if previousConfigurationExisted,
               fileManager.fileExists(atPath: previousConfigurationSnapshot.path) {
                let previous = try Data(contentsOf: previousConfigurationSnapshot)
                try writePrivate(previous, to: locations.committedConfiguration, atomically: true)
            } else if fileManager.fileExists(atPath: locations.committedConfiguration.path) {
                try fileManager.removeItem(at: locations.committedConfiguration)
            }
        }
        if fileManager.fileExists(atPath: locations.stagingDirectory.path) {
            try fileManager.removeItem(at: locations.stagingDirectory)
        }
        for reference in stagedCredentialReferences {
            try await credentialVault.discard(reference)
        }
        stagedCredentialReferences.removeAll()
        configurationCommitted = false
        stagedValidationAccepted = false
    }

    private func requireRequestedCategories(
        _ categories: [M4LegacyConfigurationCategory],
        expected: Set<M4LegacyConfigurationCategory>
    ) throws {
        guard Set(categories) == expected, Set(categories).count == categories.count else {
            throw M4OfflineMigrationAdapterError.categoryRequestMismatch
        }
    }

    private func createPrivateDirectory(_ url: URL) throws {
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func stageManagedConfigurationIfNeeded() throws {
        try createPrivateDirectory(locations.stagingDirectory)
        let data = try encoder.encode(payload.managedConfiguration)
        guard !containsAnySecret(data) else {
            throw M4OfflineMigrationAdapterError.secretEnteredManagedConfiguration
        }
        try writePrivate(data, to: locations.stagedConfiguration)
    }

    private func writePrivate(_ data: Data, to url: URL, atomically: Bool = false) throws {
        try data.write(to: url, options: atomically ? [.atomic] : [])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func permissions(at url: URL) -> Int? {
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        return (attributes?[.posixPermissions] as? NSNumber)?.intValue
    }

    private func containsAnySecret(_ data: Data) -> Bool {
        payload.credentialSecrets.values.contains { secret in
            !secret.isEmpty && data.range(of: secret) != nil
        }
    }

    private static func isInsideTemporaryDirectory(
        _ url: URL,
        fileManager: FileManager
    ) -> Bool {
        guard url.isFileURL else { return false }
        let temporary = fileManager.temporaryDirectory
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        let candidate = url
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        return candidate.hasPrefix(temporary.hasSuffix("/") ? temporary : temporary + "/")
    }
}

private struct M4OfflineRollbackManifest: Codable {
    let schemaVersion: Int
    let categories: [M4LegacyConfigurationCategory]
    let artifactNames: [String]
}

private struct M4OfflineFallbackMarker: Codable {
    let schemaVersion: Int
    let categories: [M4LegacyConfigurationCategory]
    let legacyItemsDeleted: Bool
    let runtimeActivated: Bool
}
