import Foundation
import Security

// M4-5D implements production-capable filesystem and Keychain adapters without
// wiring them into App startup, UI, Bridge activation, or migration execution.
// The transaction store depends only on injected protocols; hostless tests use
// in-memory implementations and never instantiate the Foundation/Security clients.

struct M4ProductionMigrationLocations: Equatable, Sendable {
    let supportDirectory: URL
    let transactionsDirectory: URL
    let transactionRoot: URL
    let rollbackDirectory: URL
    let stagingDirectory: URL
    let stagedConfiguration: URL
    let committedConfiguration: URL
    let fallbackMarker: URL

    static func make(
        supportDirectory: URL,
        transactionIdentifier: String
    ) throws -> Self {
        let root = supportDirectory.standardizedFileURL
        guard root.isFileURL,
              root.path.hasPrefix("/"),
              root.path != "/",
              Self.isSafeTransactionIdentifier(transactionIdentifier) else {
            throw M4ProductionMigrationAdapterError.unsafeLocation
        }

        let transactions = root.appendingPathComponent(
            "MigrationTransactions.noindex",
            isDirectory: true
        )
        let transaction = transactions.appendingPathComponent(
            transactionIdentifier,
            isDirectory: true
        )
        let rollback = transaction.appendingPathComponent("rollback", isDirectory: true)
        let staging = transaction.appendingPathComponent("staging", isDirectory: true)
        let locations = Self(
            supportDirectory: root,
            transactionsDirectory: transactions,
            transactionRoot: transaction,
            rollbackDirectory: rollback,
            stagingDirectory: staging,
            stagedConfiguration: staging.appendingPathComponent("managed-runtime-v1.json"),
            committedConfiguration: root.appendingPathComponent("managed-runtime-v1.json"),
            fallbackMarker: rollback.appendingPathComponent("legacy-fallback-retained-v1.json")
        )
        guard locations.allOwnedURLs.allSatisfy({ Self.isDescendant($0, of: root) }) else {
            throw M4ProductionMigrationAdapterError.unsafeLocation
        }
        return locations
    }

    static func live() throws -> Self {
        try make(
            supportDirectory: SupportPaths.supportDirectory,
            transactionIdentifier: "m4-5d-" + UUID().uuidString.lowercased()
        )
    }

    private var allOwnedURLs: [URL] {
        [
            transactionsDirectory,
            transactionRoot,
            rollbackDirectory,
            stagingDirectory,
            stagedConfiguration,
            committedConfiguration,
            fallbackMarker,
        ]
    }

    private static func isSafeTransactionIdentifier(_ value: String) -> Bool {
        guard (1...80).contains(value.count) else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return value.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func isDescendant(_ candidate: URL, of root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let candidatePath = candidate.standardizedFileURL.path
        return candidatePath.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
    }
}

enum M4ProductionMigrationAdapterError: Error, Equatable, Sendable {
    case unsafeLocation
    case pathOutsideAuthorizedRoot
    case symbolicLinkInAuthorizedPath
    case transactionRootAlreadyExists
    case invalidOperationOrder
    case categoryRequestMismatch
    case missingFile
    case secretEnteredManagedConfiguration
    case invalidCredentialReference
    case managedCredentialAlreadyExists
    case keychainOperationFailed
}

protocol M4MigrationFileSystemAccess: Sendable {
    func itemExists(at url: URL) async throws -> Bool
    func readFile(at url: URL) async throws -> Data
    func createPrivateDirectory(at url: URL) async throws
    func writePrivateFile(_ data: Data, to url: URL, atomically: Bool) async throws
    func removeItem(at url: URL) async throws
    func contentsOfDirectory(at url: URL) async throws -> [URL]
    func permissions(at url: URL) async throws -> Int?
}

struct M4FoundationMigrationFileSystem: M4MigrationFileSystemAccess, Sendable {
    private let authorizedRoot: URL

    init(authorizedRoot: URL) throws {
        let root = authorizedRoot.standardizedFileURL
        guard root.isFileURL, root.path.hasPrefix("/"), root.path != "/" else {
            throw M4ProductionMigrationAdapterError.unsafeLocation
        }
        self.authorizedRoot = root
    }

    func itemExists(at url: URL) throws -> Bool {
        let candidate = try validated(url)
        return FileManager.default.fileExists(atPath: candidate.path)
    }

    func readFile(at url: URL) throws -> Data {
        let candidate = try validated(url)
        guard FileManager.default.fileExists(atPath: candidate.path) else {
            throw M4ProductionMigrationAdapterError.missingFile
        }
        return try Data(contentsOf: candidate)
    }

    func createPrivateDirectory(at url: URL) throws {
        let candidate = try validated(url)
        try FileManager.default.createDirectory(
            at: candidate,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        _ = try validated(candidate)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: candidate.path
        )
    }

    func writePrivateFile(_ data: Data, to url: URL, atomically: Bool) throws {
        let candidate = try validated(url)
        _ = try validated(candidate.deletingLastPathComponent())
        try data.write(to: candidate, options: atomically ? [.atomic] : [])
        _ = try validated(candidate)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: candidate.path
        )
    }

    func removeItem(at url: URL) throws {
        let candidate = try validated(url)
        if FileManager.default.fileExists(atPath: candidate.path) {
            try FileManager.default.removeItem(at: candidate)
        }
    }

    func contentsOfDirectory(at url: URL) throws -> [URL] {
        let candidate = try validated(url)
        return try FileManager.default.contentsOfDirectory(
            at: candidate,
            includingPropertiesForKeys: [.isSymbolicLinkKey]
        ).map(validated)
    }

    func permissions(at url: URL) throws -> Int? {
        let candidate = try validated(url)
        let attributes = try FileManager.default.attributesOfItem(atPath: candidate.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue
    }

    private func validated(_ url: URL) throws -> URL {
        let candidate = url.standardizedFileURL
        let rootPath = authorizedRoot.path
        let candidatePath = candidate.path
        guard candidatePath == rootPath
                || candidatePath.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/") else {
            throw M4ProductionMigrationAdapterError.pathOutsideAuthorizedRoot
        }

        let resolvedRoot = authorizedRoot.resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolvedCandidate == resolvedRoot
                || resolvedCandidate.hasPrefix(
                    resolvedRoot.hasSuffix("/") ? resolvedRoot : resolvedRoot + "/"
                ) else {
            throw M4ProductionMigrationAdapterError.pathOutsideAuthorizedRoot
        }
        try rejectExistingSymbolicLinkComponents(from: authorizedRoot, to: candidate)
        return candidate
    }

    private func rejectExistingSymbolicLinkComponents(from root: URL, to candidate: URL) throws {
        let manager = FileManager.default
        let rootPath = root.path
        let suffix = String(candidate.path.dropFirst(rootPath.count))
        var current = root
        var components = suffix.split(separator: "/").map(String.init)
        components.insert("", at: 0)
        for component in components {
            if !component.isEmpty {
                current.appendPathComponent(component)
            }
            guard manager.fileExists(atPath: current.path) else { continue }
            let attributes = try manager.attributesOfItem(atPath: current.path)
            if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                throw M4ProductionMigrationAdapterError.symbolicLinkInAuthorizedPath
            }
        }
    }
}

protocol M4VersionedGenericPasswordAccess: Sendable {
    func contains(_ reference: M4VersionedCredentialReference) async throws -> Bool
    func read(_ reference: M4VersionedCredentialReference) async throws -> Data?
    func add(_ data: Data, for reference: M4VersionedCredentialReference) async throws
    func delete(_ reference: M4VersionedCredentialReference) async throws
}

struct M4SecurityVersionedGenericPasswordClient: M4VersionedGenericPasswordAccess, Sendable {
    func contains(_ reference: M4VersionedCredentialReference) throws -> Bool {
        let query = try baseQuery(reference)
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else {
            throw M4ProductionMigrationAdapterError.keychainOperationFailed
        }
        return true
    }

    func read(_ reference: M4VersionedCredentialReference) throws -> Data? {
        var query = try baseQuery(reference)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw M4ProductionMigrationAdapterError.keychainOperationFailed
        }
        return data
    }

    func add(_ data: Data, for reference: M4VersionedCredentialReference) throws {
        guard !data.isEmpty else {
            throw M4ProductionMigrationAdapterError.keychainOperationFailed
        }
        let access = try KeychainAccessPolicy.makeManagedRuntimeAccess(
            label: reference.purpose == .bridgeToken
                ? "VibeStick Managed Bridge Token"
                : "VibeStick Managed ASR API Key"
        )
        let attributes: [String: Any] = try baseQuery(reference).merging([
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrAccess as String: access,
        ]) { _, new in new }
        guard SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess else {
            throw M4ProductionMigrationAdapterError.keychainOperationFailed
        }
    }

    func delete(_ reference: M4VersionedCredentialReference) throws {
        let status = SecItemDelete(try baseQuery(reference) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw M4ProductionMigrationAdapterError.keychainOperationFailed
        }
    }

    private func baseQuery(
        _ reference: M4VersionedCredentialReference
    ) throws -> [String: Any] {
        guard reference.isManagedVersion else {
            throw M4ProductionMigrationAdapterError.invalidCredentialReference
        }
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: M4VersionedCredentialReference.service,
            kSecAttrAccount as String: reference.account,
        ]
    }
}

actor M4VersionedKeychainCredentialVault: M4OfflineCredentialVault {
    private let client: any M4VersionedGenericPasswordAccess
    private var referencesCreatedByThisTransaction: Set<M4VersionedCredentialReference> = []

    init(client: any M4VersionedGenericPasswordAccess) {
        self.client = client
    }

    static func live() -> M4VersionedKeychainCredentialVault {
        M4VersionedKeychainCredentialVault(client: M4SecurityVersionedGenericPasswordClient())
    }

    func stage(_ secret: Data, for reference: M4VersionedCredentialReference) async throws {
        guard reference.isManagedVersion, !secret.isEmpty else {
            throw M4ProductionMigrationAdapterError.invalidCredentialReference
        }
        guard !referencesCreatedByThisTransaction.contains(reference),
              try await client.contains(reference) == false else {
            throw M4ProductionMigrationAdapterError.managedCredentialAlreadyExists
        }
        try await client.add(secret, for: reference)
        referencesCreatedByThisTransaction.insert(reference)
    }

    func read(_ reference: M4VersionedCredentialReference) async throws -> Data? {
        guard reference.isManagedVersion else {
            throw M4ProductionMigrationAdapterError.invalidCredentialReference
        }
        return try await client.read(reference)
    }

    func contains(_ reference: M4VersionedCredentialReference) async throws -> Bool {
        guard reference.isManagedVersion else {
            throw M4ProductionMigrationAdapterError.invalidCredentialReference
        }
        return try await client.contains(reference)
    }

    func discard(_ reference: M4VersionedCredentialReference) async throws {
        guard reference.isManagedVersion else {
            throw M4ProductionMigrationAdapterError.invalidCredentialReference
        }
        guard referencesCreatedByThisTransaction.contains(reference) else { return }
        try await client.delete(reference)
        referencesCreatedByThisTransaction.remove(reference)
    }

    func legacyAccountsRemainUntouched() -> Bool {
        true
    }
}

actor M4ProductionMigrationTransactionStore: M4LegacyMigrationTransactionStoring {
    nonisolated let locations: M4ProductionMigrationLocations

    private let fileSystem: any M4MigrationFileSystemAccess
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
        locations: M4ProductionMigrationLocations,
        payload: M4OfflineMigrationPayload,
        credentialVault: any M4OfflineCredentialVault,
        fileSystem: any M4MigrationFileSystemAccess
    ) throws {
        self.locations = locations
        self.payload = try payload.validated()
        self.credentialVault = credentialVault
        self.fileSystem = fileSystem
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
    }

    static func live(
        payload: M4OfflineMigrationPayload
    ) throws -> M4ProductionMigrationTransactionStore {
        let locations = try M4ProductionMigrationLocations.live()
        return try M4ProductionMigrationTransactionStore(
            locations: locations,
            payload: payload,
            credentialVault: M4VersionedKeychainCredentialVault.live(),
            fileSystem: M4FoundationMigrationFileSystem(
                authorizedRoot: locations.supportDirectory
            )
        )
    }

    func preparePrivateRollback(
        for categories: [M4LegacyConfigurationCategory]
    ) async throws {
        try requireRequestedCategories(categories, expected: payload.categories)
        guard !prepared else {
            throw M4ProductionMigrationAdapterError.invalidOperationOrder
        }
        guard try await fileSystem.itemExists(at: locations.transactionRoot) == false else {
            throw M4ProductionMigrationAdapterError.transactionRootAlreadyExists
        }

        try await fileSystem.createPrivateDirectory(at: locations.transactionsDirectory)
        try await fileSystem.createPrivateDirectory(at: locations.transactionRoot)
        try await fileSystem.createPrivateDirectory(at: locations.rollbackDirectory)
        let manifest = M4ProductionRollbackManifest(
            schemaVersion: 1,
            categories: categories,
            artifactNames: payload.rollbackArtifacts.map(\.fileName).sorted()
        )
        try await fileSystem.writePrivateFile(
            try encoder.encode(manifest),
            to: locations.rollbackDirectory.appendingPathComponent("rollback-manifest-v1.json"),
            atomically: false
        )
        for artifact in payload.rollbackArtifacts {
            try await fileSystem.writePrivateFile(
                artifact.data,
                to: locations.rollbackDirectory.appendingPathComponent(artifact.fileName),
                atomically: false
            )
        }

        previousConfigurationExisted = try await fileSystem.itemExists(
            at: locations.committedConfiguration
        )
        if previousConfigurationExisted {
            try await fileSystem.writePrivateFile(
                try await fileSystem.readFile(at: locations.committedConfiguration),
                to: previousConfigurationSnapshot,
                atomically: false
            )
        }
        prepared = true
    }

    func stageVersionedKeychainItems(
        for categories: [M4LegacyConfigurationCategory]
    ) async throws {
        guard prepared, stagedCredentialReferences.isEmpty else {
            throw M4ProductionMigrationAdapterError.invalidOperationOrder
        }
        let expected = Set(payload.credentialSecrets.keys.map(\.legacyCategory))
        try requireRequestedCategories(categories, expected: expected)
        for purpose in M4CredentialPurpose.allCases where payload.credentialSecrets[purpose] != nil {
            guard let secret = payload.credentialSecrets[purpose],
                  let reference = payload.managedConfiguration.credentialReference(for: purpose),
                  reference.isManagedVersion else {
                throw M4ProductionMigrationAdapterError.invalidCredentialReference
            }
            try await credentialVault.stage(secret, for: reference)
            stagedCredentialReferences.append(reference)
        }
        if !payload.categories.contains(where: \.requiresConfigurationWrite) {
            try await stageManagedConfigurationIfNeeded()
        }
    }

    func stageConfigurationFiles(
        for categories: [M4LegacyConfigurationCategory]
    ) async throws {
        guard prepared else {
            throw M4ProductionMigrationAdapterError.invalidOperationOrder
        }
        try requireRequestedCategories(
            categories,
            expected: Set(payload.categories.filter(\.requiresConfigurationWrite))
        )
        try await stageManagedConfigurationIfNeeded()
    }

    func preservePasteIdentity() throws {
        guard prepared,
              payload.categories.contains(.runtimeComponents),
              let identity = payload.existingPasteIdentity else {
            throw M4ProductionMigrationAdapterError.invalidOperationOrder
        }
        preservedPasteIdentity = identity
    }

    func validateStagedState() async throws -> M4StagedMigrationValidation {
        guard prepared else {
            throw M4ProductionMigrationAdapterError.invalidOperationOrder
        }
        let rollbackFiles = try await fileSystem.contentsOfDirectory(at: locations.rollbackDirectory)
        let references = payload.managedConfiguration.credentialReferences
        var allCredentialsExist = true
        for reference in references where try await credentialVault.contains(reference) == false {
            allCredentialsExist = false
        }
        let stagedData: Data?
        if try await fileSystem.itemExists(at: locations.stagedConfiguration) {
            stagedData = try await fileSystem.readFile(at: locations.stagedConfiguration)
        } else {
            stagedData = nil
        }
        var rollbackFilesArePrivate = true
        for file in rollbackFiles where try await fileSystem.permissions(at: file) != 0o600 {
            rollbackFilesArePrivate = false
        }
        let validation = M4StagedMigrationValidation(
            rollbackDirectoryIsPrivate: try await fileSystem.permissions(
                at: locations.rollbackDirectory
            ) == 0o700,
            rollbackFilesArePrivate: rollbackFilesArePrivate,
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

    func atomicallyCommitConfiguration() async throws {
        guard stagedValidationAccepted else {
            throw M4ProductionMigrationAdapterError.invalidOperationOrder
        }
        guard try await fileSystem.itemExists(at: locations.stagedConfiguration) else {
            configurationCommitted = true
            return
        }
        try await fileSystem.writePrivateFile(
            try await fileSystem.readFile(at: locations.stagedConfiguration),
            to: locations.committedConfiguration,
            atomically: true
        )
        try await fileSystem.removeItem(at: locations.stagedConfiguration)
        configurationCommitted = true
    }

    func retainLegacyFallback() async throws {
        guard configurationCommitted else {
            throw M4ProductionMigrationAdapterError.invalidOperationOrder
        }
        let marker = M4ProductionFallbackMarker(
            schemaVersion: 1,
            categories: payload.categories.sorted { $0.rawValue < $1.rawValue },
            legacyItemsDeleted: false,
            runtimeActivated: false
        )
        try await fileSystem.writePrivateFile(
            try encoder.encode(marker),
            to: locations.fallbackMarker,
            atomically: false
        )
    }

    func restorePreviousStateAndDiscardStaging() async throws {
        if configurationCommitted {
            if previousConfigurationExisted,
               try await fileSystem.itemExists(at: previousConfigurationSnapshot) {
                try await fileSystem.writePrivateFile(
                    try await fileSystem.readFile(at: previousConfigurationSnapshot),
                    to: locations.committedConfiguration,
                    atomically: true
                )
            } else {
                try await fileSystem.removeItem(at: locations.committedConfiguration)
            }
        }
        try await fileSystem.removeItem(at: locations.stagingDirectory)
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
            throw M4ProductionMigrationAdapterError.categoryRequestMismatch
        }
    }

    private func stageManagedConfigurationIfNeeded() async throws {
        try await fileSystem.createPrivateDirectory(at: locations.stagingDirectory)
        let data = try encoder.encode(payload.managedConfiguration)
        guard !containsAnySecret(data) else {
            throw M4ProductionMigrationAdapterError.secretEnteredManagedConfiguration
        }
        try await fileSystem.writePrivateFile(
            data,
            to: locations.stagedConfiguration,
            atomically: false
        )
    }

    private func containsAnySecret(_ data: Data) -> Bool {
        payload.credentialSecrets.values.contains { secret in
            !secret.isEmpty && data.range(of: secret) != nil
        }
    }
}

private struct M4ProductionRollbackManifest: Codable {
    let schemaVersion: Int
    let categories: [M4LegacyConfigurationCategory]
    let artifactNames: [String]
}

private struct M4ProductionFallbackMarker: Codable {
    let schemaVersion: Int
    let categories: [M4LegacyConfigurationCategory]
    let legacyItemsDeleted: Bool
    let runtimeActivated: Bool
}
