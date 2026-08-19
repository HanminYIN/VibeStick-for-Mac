import Foundation
import Security

// M4-5E connects restricted legacy readers to the existing double-preflight
// coordinator without exposing an App-startup or UI action. Constructing this
// entry is inert. Filesystem/Keychain access happens only when an explicit
// caller invokes discover() or migrate(), and the production transaction store
// is not created until the second migration preflight has completed.

enum M4RestrictedLegacyFile: String, CaseIterable, Hashable, Sendable {
    case legacyEnvironment = "legacy-environment"
    case appPreferences = "app-preferences"
    case deviceConfiguration = "device-configuration"
    case recordingState = "recording-state"

    var fileName: String {
        switch self {
        case .legacyEnvironment: ".env"
        case .appPreferences: "config-v1.json"
        case .deviceConfiguration: "device-config-v1.json"
        case .recordingState: "recording.json"
        }
    }

    var maximumByteCount: Int {
        switch self {
        case .recordingState: 256 * 1_024
        case .legacyEnvironment, .appPreferences, .deviceConfiguration: 1_024 * 1_024
        }
    }
}

struct M4RestrictedLegacyFileSnapshot: Equatable, Sendable {
    let source: M4RestrictedLegacyFile
    let exists: Bool
    let data: Data?
    let permissions: Int?

    static func missing(_ source: M4RestrictedLegacyFile) -> Self {
        Self(source: source, exists: false, data: nil, permissions: nil)
    }
}

struct M4LegacyFileAllowlist: Equatable, Sendable {
    let supportDirectory: URL

    init(supportDirectory: URL) throws {
        let root = supportDirectory.standardizedFileURL
        guard root.isFileURL, root.path.hasPrefix("/"), root.path != "/" else {
            throw M4LiveMigrationEntryError.unsafeFileScope
        }
        self.supportDirectory = root
    }

    func url(for source: M4RestrictedLegacyFile) -> URL {
        supportDirectory.appendingPathComponent(source.fileName, isDirectory: false)
    }

    var allowedURLs: Set<URL> {
        Set(M4RestrictedLegacyFile.allCases.map { url(for: $0) })
    }
}

protocol M4RestrictedLegacyFileReading: Sendable {
    func read(_ source: M4RestrictedLegacyFile) async throws -> M4RestrictedLegacyFileSnapshot
}

struct M4FoundationRestrictedLegacyFileReader: M4RestrictedLegacyFileReading, Sendable {
    private let allowlist: M4LegacyFileAllowlist

    init(allowlist: M4LegacyFileAllowlist) {
        self.allowlist = allowlist
    }

    func read(_ source: M4RestrictedLegacyFile) throws -> M4RestrictedLegacyFileSnapshot {
        let manager = FileManager.default
        let candidate = allowlist.url(for: source).standardizedFileURL
        guard allowlist.allowedURLs.contains(candidate) else {
            throw M4LiveMigrationEntryError.unsafeFileScope
        }
        try rejectSymbolicLinkOrEscape(candidate, fileManager: manager)
        guard manager.fileExists(atPath: candidate.path) else {
            return .missing(source)
        }

        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try manager.attributesOfItem(atPath: candidate.path)
        } catch {
            throw M4LiveMigrationEntryError.legacyFileReadFailed
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw M4LiveMigrationEntryError.legacyFileIsNotRegular
        }
        let byteCount = (attributes[.size] as? NSNumber)?.intValue ?? -1
        guard byteCount >= 0, byteCount <= source.maximumByteCount else {
            throw M4LiveMigrationEntryError.legacyFileTooLarge
        }
        let data: Data
        do {
            data = try Data(contentsOf: candidate, options: [.mappedIfSafe])
        } catch {
            throw M4LiveMigrationEntryError.legacyFileReadFailed
        }
        guard data.count == byteCount else {
            throw M4LiveMigrationEntryError.legacyFileChangedWhileReading
        }
        return M4RestrictedLegacyFileSnapshot(
            source: source,
            exists: true,
            data: data,
            permissions: (attributes[.posixPermissions] as? NSNumber)?.intValue
        )
    }

    private func rejectSymbolicLinkOrEscape(
        _ candidate: URL,
        fileManager: FileManager
    ) throws {
        let root = allowlist.supportDirectory
        let rootPath = root.path
        guard candidate.path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/"),
              root.resolvingSymlinksInPath().standardizedFileURL == root,
              candidate.resolvingSymlinksInPath().standardizedFileURL == candidate else {
            throw M4LiveMigrationEntryError.unsafeFileScope
        }
        for url in [root, candidate] where fileManager.fileExists(atPath: url.path) {
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                throw M4LiveMigrationEntryError.symbolicLinkInLegacyScope
            }
        }
    }
}

struct M4LegacyCredentialReference: Equatable, Hashable, Sendable {
    static let service = "io.github.hanminyin.vibestick"

    let purpose: M4CredentialPurpose
    let account: String

    static func legacy(_ purpose: M4CredentialPurpose) -> Self {
        Self(
            purpose: purpose,
            account: purpose == .bridgeToken ? "bridge-token" : "asr-api-key"
        )
    }

    var isAllowedLegacyReference: Bool {
        self == Self.legacy(purpose)
    }
}

protocol M4RestrictedLegacyCredentialReading: Sendable {
    func containsCredential(for purpose: M4CredentialPurpose) async throws -> Bool
    func readCredential(for purpose: M4CredentialPurpose) async throws -> Data?
}

struct M4SecurityRestrictedLegacyCredentialReader: M4RestrictedLegacyCredentialReading, Sendable {
    func containsCredential(for purpose: M4CredentialPurpose) throws -> Bool {
        let query = try baseQuery(for: purpose)
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else {
            throw M4LiveMigrationEntryError.legacyCredentialReadFailed
        }
        return true
    }

    func readCredential(for purpose: M4CredentialPurpose) throws -> Data? {
        var query = try baseQuery(for: purpose)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw M4LiveMigrationEntryError.legacyCredentialReadFailed
        }
        return data
    }

    private func baseQuery(for purpose: M4CredentialPurpose) throws -> [String: Any] {
        let reference = M4LegacyCredentialReference.legacy(purpose)
        guard reference.isAllowedLegacyReference else {
            throw M4LiveMigrationEntryError.unsafeCredentialScope
        }
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: M4LegacyCredentialReference.service,
            kSecAttrAccount as String: reference.account,
        ]
    }
}

struct M4LegacyRuntimeFacts: Equatable, Sendable {
    let runtimeComponentsInstalled: Bool
    let runtimeOwnershipIsUnknown: Bool
    let activeVoiceWorkExists: Bool
    let pasteIdentity: String?
    let accessibilityPermissionGranted: Bool
    let soundEnabled: Bool?
}

enum M4ASRConfigurationSource: String, CaseIterable, Hashable, Sendable {
    case currentApp
    case legacyEnvironment
}

struct M4RedactedASRConfigurationConflict: Equatable, Sendable {
    let availableSources: Set<M4ASRConfigurationSource>

    static let currentAppAndLegacyEnvironment = Self(
        availableSources: [.currentApp, .legacyEnvironment]
    )
}

struct M4RedactedLegacyMigrationDiscovery: Equatable, Sendable {
    let evidence: M4RedactedLegacyEvidence
    let asrConfigurationConflict: M4RedactedASRConfigurationConflict?
}

protocol M4LegacyRuntimeFactsReading: Sendable {
    func readRuntimeFacts() async throws -> M4LegacyRuntimeFacts
}

struct M4PreparedLegacyMigration: Equatable, Sendable {
    let evidence: M4RedactedLegacyEvidence
    let payload: M4OfflineMigrationPayload
    let resolvedASRConfigurationSource: M4ASRConfigurationSource?

    init(
        evidence: M4RedactedLegacyEvidence,
        payload: M4OfflineMigrationPayload,
        resolvedASRConfigurationSource: M4ASRConfigurationSource? = nil
    ) {
        self.evidence = evidence
        self.payload = payload
        self.resolvedASRConfigurationSource = resolvedASRConfigurationSource
    }

    var discovery: M4LegacyDiscovery {
        M4LegacyDiscovery(
            detectedCategories: evidence.detectedCategories,
            legacyFileExists: evidence.legacyFileExists,
            legacyFilePermissionsArePrivate: evidence.legacyFilePermissionsArePrivate,
            unknownRuntimeOwnerDetected: evidence.runtimeOwnershipIsUnknown,
            activeVoiceWorkDetected: evidence.activeVoiceWorkExists
        )
    }
}

protocol M4PreparedLegacyMigrationReading: Sendable {
    func readPreparedLegacyMigration(
        asrConfigurationSource: M4ASRConfigurationSource?
    ) async throws -> M4PreparedLegacyMigration
}

protocol M4ExplicitLegacyMigrationReading: M4PreparedLegacyMigrationReading {
    func readRedactedLegacyDiscovery() async throws -> M4RedactedLegacyMigrationDiscovery
}

struct M4RestrictedLegacyMigrationSource: M4ExplicitLegacyMigrationReading, Sendable {
    private let files: any M4RestrictedLegacyFileReading
    private let credentials: any M4RestrictedLegacyCredentialReading
    private let runtime: any M4LegacyRuntimeFactsReading

    init(
        files: any M4RestrictedLegacyFileReading,
        credentials: any M4RestrictedLegacyCredentialReading,
        runtime: any M4LegacyRuntimeFactsReading
    ) {
        self.files = files
        self.credentials = credentials
        self.runtime = runtime
    }

    func readRedactedLegacyDiscovery() async throws -> M4RedactedLegacyMigrationDiscovery {
        let environment = try await files.read(.legacyEnvironment)
        let preferences = try await files.read(.appPreferences)
        let deviceConfiguration = try await files.read(.deviceConfiguration)
        let recording = try await files.read(.recordingState)
        let runtimeFacts = try await runtime.readRuntimeFacts()
        let environmentValues = try decodedEnvironment(environment)
        let appConfiguration = try decodedAppConfiguration(preferences)
        let deviceConfigurationValue = try decodedDeviceConfiguration(deviceConfiguration)

        let bridgeStored = try await credentials.containsCredential(for: .bridgeToken)
        let asrStored = try await credentials.containsCredential(for: .asrAPIKey)
        let bridgePresent = bridgeStored
            || nonEmpty(environmentValues["VIBE_STICK_BRIDGE_TOKEN"]) != nil
        let asrPresent = asrStored
            || nonEmpty(environmentValues["VIBE_STICK_ASR_API_KEY"]) != nil
            || nonEmpty(environmentValues["VIBE_STICK_GROQ_API_KEY"]) != nil

        let preferenceASR = try appConfiguration?.asr.map(mapASRConfiguration)
        let environmentASR = try mapEnvironmentASR(environmentValues)
        let asrConflict = redactedASRConflict(
            preference: preferenceASR,
            environment: environmentASR
        )
        let asr = preferenceASR ?? environmentASR
        if asrConflict == nil, asr?.requiresCredential == true, !asrPresent {
            throw M4LiveMigrationEntryError.missingRequiredCredential
        }
        let projectPresentation = try mappedProjectPresentation(
            environmentValues: environmentValues,
            deviceConfiguration: deviceConfigurationValue
        )
        let agentProvider = try mappedAgentProvider(environmentValues)
        let voiceDelivery = mappedVoiceDelivery(environmentValues)
        let recordingVoiceWorkExists = try recordingContainsActiveVoiceWork(recording)

        var categories: Set<M4LegacyConfigurationCategory> = []
        if runtimeFacts.runtimeComponentsInstalled { categories.insert(.runtimeComponents) }
        if bridgePresent { categories.insert(.bridgeCredential) }
        if asrPresent { categories.insert(.asrCredential) }
        if asr != nil { categories.insert(.asrConfiguration) }
        if agentProvider != nil { categories.insert(.agentProvider) }
        if projectPresentation != nil { categories.insert(.projectPresentation) }
        if voiceDelivery != nil { categories.insert(.voiceDelivery) }
        if runtimeFacts.soundEnabled != nil { categories.insert(.soundPreference) }
        if runtimeFacts.accessibilityPermissionGranted { categories.insert(.accessibilityPermission) }

        let pasteIdentity = nonEmpty(runtimeFacts.pasteIdentity)
        return M4RedactedLegacyMigrationDiscovery(
            evidence: M4RedactedLegacyEvidence(
                detectedCategories: categories,
                legacyFileExists: environment.exists,
                legacyFilePermissionsArePrivate: !environment.exists
                    || environment.permissions.map { ($0 & 0o077) == 0 } == true,
                runtimeOwnershipIsUnknown: runtimeFacts.runtimeOwnershipIsUnknown
                    || (runtimeFacts.runtimeComponentsInstalled && pasteIdentity == nil),
                activeVoiceWorkExists: runtimeFacts.activeVoiceWorkExists
                    || recordingVoiceWorkExists
            ),
            asrConfigurationConflict: asrConflict
        )
    }

    func readPreparedLegacyMigration(
        asrConfigurationSource: M4ASRConfigurationSource?
    ) async throws -> M4PreparedLegacyMigration {
        let environment = try await files.read(.legacyEnvironment)
        let preferences = try await files.read(.appPreferences)
        let deviceConfiguration = try await files.read(.deviceConfiguration)
        let recording = try await files.read(.recordingState)
        let runtimeFacts = try await runtime.readRuntimeFacts()

        let environmentValues = try decodedEnvironment(environment)
        let appConfiguration = try decodedAppConfiguration(preferences)
        let deviceConfigurationValue = try decodedDeviceConfiguration(deviceConfiguration)

        let bridgeSecret = try normalizedSecret(
            try await credentials.readCredential(for: .bridgeToken),
            fallback: environmentValues["VIBE_STICK_BRIDGE_TOKEN"]
        )
        let asrSecret = try normalizedSecret(
            try await credentials.readCredential(for: .asrAPIKey),
            fallback: nonEmpty(environmentValues["VIBE_STICK_ASR_API_KEY"])
                ?? nonEmpty(environmentValues["VIBE_STICK_GROQ_API_KEY"])
        )

        let preferenceASR = try appConfiguration?.asr.map(mapASRConfiguration)
        let environmentASR = try mapEnvironmentASR(environmentValues)
        let asrResolution = try resolvedASRConfiguration(
            preference: preferenceASR,
            environment: environmentASR,
            selectedSource: asrConfigurationSource
        )
        let asr = asrResolution.configuration
        if asr?.requiresCredential == true, asrSecret == nil {
            throw M4LiveMigrationEntryError.missingRequiredCredential
        }

        let projectPresentation = try mappedProjectPresentation(
            environmentValues: environmentValues,
            deviceConfiguration: deviceConfigurationValue
        )
        let agentProvider = try mappedAgentProvider(environmentValues)
        let voiceDelivery = mappedVoiceDelivery(environmentValues)
        let recordingVoiceWorkExists = try recordingContainsActiveVoiceWork(recording)
        let activeVoice = runtimeFacts.activeVoiceWorkExists || recordingVoiceWorkExists

        var categories: Set<M4LegacyConfigurationCategory> = []
        var credentialSecrets: [M4CredentialPurpose: Data] = [:]
        var credentialReferences: [M4VersionedCredentialReference] = []
        if runtimeFacts.runtimeComponentsInstalled { categories.insert(.runtimeComponents) }
        if let bridgeSecret {
            categories.insert(.bridgeCredential)
            credentialSecrets[.bridgeToken] = bridgeSecret
            credentialReferences.append(.managed(.bridgeToken))
        }
        if let asrSecret {
            categories.insert(.asrCredential)
            credentialSecrets[.asrAPIKey] = asrSecret
            credentialReferences.append(.managed(.asrAPIKey))
        }
        if asr != nil { categories.insert(.asrConfiguration) }
        if agentProvider != nil { categories.insert(.agentProvider) }
        if projectPresentation != nil { categories.insert(.projectPresentation) }
        if voiceDelivery != nil { categories.insert(.voiceDelivery) }
        if runtimeFacts.soundEnabled != nil { categories.insert(.soundPreference) }
        if runtimeFacts.accessibilityPermissionGranted { categories.insert(.accessibilityPermission) }

        let pasteIdentity = nonEmpty(runtimeFacts.pasteIdentity)
        let unknownRuntimeOwner = runtimeFacts.runtimeOwnershipIsUnknown
            || (runtimeFacts.runtimeComponentsInstalled && pasteIdentity == nil)
        let managedConfiguration = M4ManagedRuntimeConfiguration(
            schemaVersion: M4ManagedRuntimeConfiguration.currentSchemaVersion,
            credentialReferences: credentialReferences,
            asr: asr,
            agentProvider: agentProvider,
            projectPresentation: projectPresentation,
            voiceDelivery: voiceDelivery,
            soundEnabled: runtimeFacts.soundEnabled
        )
        _ = try managedConfiguration.validated()

        let evidence = M4RedactedLegacyEvidence(
            detectedCategories: categories,
            legacyFileExists: environment.exists,
            legacyFilePermissionsArePrivate: !environment.exists
                || environment.permissions.map { ($0 & 0o077) == 0 } == true,
            runtimeOwnershipIsUnknown: unknownRuntimeOwner,
            activeVoiceWorkExists: activeVoice
        )
        let payload = M4OfflineMigrationPayload(
            categories: categories,
            credentialSecrets: credentialSecrets,
            managedConfiguration: managedConfiguration,
            rollbackArtifacts: rollbackArtifacts(
                environment: environment,
                preferences: preferences,
                deviceConfiguration: deviceConfiguration
            ),
            existingPasteIdentity: runtimeFacts.runtimeComponentsInstalled ? pasteIdentity : nil
        )
        return M4PreparedLegacyMigration(
            evidence: evidence,
            payload: payload,
            resolvedASRConfigurationSource: asrResolution.source
        )
    }

    private func redactedASRConflict(
        preference: M4ManagedASRConfiguration?,
        environment: M4ManagedASRConfiguration?
    ) -> M4RedactedASRConfigurationConflict? {
        guard let preference, let environment, preference != environment else { return nil }
        return .currentAppAndLegacyEnvironment
    }

    private func resolvedASRConfiguration(
        preference: M4ManagedASRConfiguration?,
        environment: M4ManagedASRConfiguration?,
        selectedSource: M4ASRConfigurationSource?
    ) throws -> (configuration: M4ManagedASRConfiguration?, source: M4ASRConfigurationSource?) {
        if let preference, let environment, preference != environment {
            guard let selectedSource else {
                throw M4LiveMigrationEntryError.asrConfigurationSourceSelectionRequired
            }
            return switch selectedSource {
            case .currentApp: (preference, .currentApp)
            case .legacyEnvironment: (environment, .legacyEnvironment)
            }
        }
        guard selectedSource == nil else {
            throw M4LiveMigrationEntryError.asrConfigurationSourceSelectionMismatch
        }
        return (preference ?? environment, nil)
    }

    private func decodedEnvironment(
        _ snapshot: M4RestrictedLegacyFileSnapshot
    ) throws -> [String: String] {
        guard snapshot.exists else { return [:] }
        guard let data = snapshot.data, let text = String(data: data, encoding: .utf8) else {
            throw M4LiveMigrationEntryError.invalidLegacyEncoding
        }
        return LegacyEnvironmentParser.parse(text)
    }

    private func decodedAppConfiguration(
        _ snapshot: M4RestrictedLegacyFileSnapshot
    ) throws -> AppConfiguration? {
        guard snapshot.exists else { return nil }
        guard let data = snapshot.data,
              let value = try? JSONDecoder().decode(AppConfiguration.self, from: data),
              value.schemaVersion == AppConfiguration.currentSchemaVersion else {
            throw M4LiveMigrationEntryError.invalidLegacyConfiguration
        }
        return value
    }

    private func decodedDeviceConfiguration(
        _ snapshot: M4RestrictedLegacyFileSnapshot
    ) throws -> DeviceConfiguration? {
        guard snapshot.exists else { return nil }
        guard let data = snapshot.data,
              let value = try? JSONDecoder().decode(DeviceConfiguration.self, from: data),
              value.schemaVersion == DeviceConfiguration.schemaVersion else {
            throw M4LiveMigrationEntryError.invalidLegacyConfiguration
        }
        return value.normalized
    }

    private func normalizedSecret(_ data: Data?, fallback: String?) throws -> Data? {
        if let data {
            guard let value = String(data: data, encoding: .utf8), let cleaned = nonEmpty(value) else {
                throw M4LiveMigrationEntryError.invalidLegacyCredential
            }
            return Data(cleaned.utf8)
        }
        guard let cleaned = nonEmpty(fallback) else { return nil }
        return Data(cleaned.utf8)
    }

    private func mapASRConfiguration(
        _ configuration: ASRConfiguration
    ) throws -> M4ManagedASRConfiguration {
        let value: ASRConfiguration
        do {
            value = try configuration.validated()
        } catch {
            throw M4LiveMigrationEntryError.invalidLegacyConfiguration
        }
        return M4ManagedASRConfiguration(
            provider: value.provider.rawValue,
            baseURL: value.normalized.baseURL,
            model: value.normalized.model,
            language: value.normalized.language,
            localCommand: value.normalized.localCommand
        )
    }

    private func mapEnvironmentASR(
        _ values: [String: String]
    ) throws -> M4ManagedASRConfiguration? {
        if let command = nonEmpty(values["VIBE_STICK_TRANSCRIBE_CMD"]) {
            return M4ManagedASRConfiguration(
                provider: ASRProvider.localCommand.rawValue,
                baseURL: "",
                model: "",
                language: nonEmpty(values["VIBE_STICK_ASR_LANGUAGE"]) ?? "zh",
                localCommand: command
            )
        }
        let genericFieldsPresent = [
            "VIBE_STICK_ASR_PROVIDER", "VIBE_STICK_ASR_BASE_URL",
            "VIBE_STICK_ASR_MODEL", "VIBE_STICK_ASR_LANGUAGE",
        ].contains { nonEmpty(values[$0]) != nil }
        let groqFieldsPresent = [
            "VIBE_STICK_GROQ_API_KEY", "VIBE_STICK_GROQ_MODEL",
            "VIBE_STICK_GROQ_LANGUAGE",
        ].contains { nonEmpty(values[$0]) != nil }
        guard genericFieldsPresent || groqFieldsPresent else { return nil }

        let provider: ASRProvider
        if let raw = nonEmpty(values["VIBE_STICK_ASR_PROVIDER"]),
           let mapped = ASRProvider.fromLegacyID(raw) {
            provider = mapped
        } else if nonEmpty(values["VIBE_STICK_ASR_PROVIDER"]) == nil, groqFieldsPresent {
            provider = .groq
        } else {
            throw M4LiveMigrationEntryError.invalidLegacyConfiguration
        }
        guard provider != .localCommand else {
            throw M4LiveMigrationEntryError.invalidLegacyConfiguration
        }
        let preset = ASRConfiguration.preset(provider)
        let configuration = ASRConfiguration(
            provider: provider,
            baseURL: nonEmpty(values["VIBE_STICK_ASR_BASE_URL"]) ?? preset.baseURL,
            model: nonEmpty(values["VIBE_STICK_ASR_MODEL"])
                ?? nonEmpty(values["VIBE_STICK_GROQ_MODEL"])
                ?? preset.model,
            language: nonEmpty(values["VIBE_STICK_ASR_LANGUAGE"])
                ?? nonEmpty(values["VIBE_STICK_GROQ_LANGUAGE"])
                ?? preset.language,
            localCommand: ""
        )
        return try mapASRConfiguration(configuration)
    }

    private func mappedProjectPresentation(
        environmentValues: [String: String],
        deviceConfiguration: DeviceConfiguration?
    ) throws -> M4ManagedProjectPresentation? {
        let environmentName = nonEmpty(environmentValues["VIBE_STICK_PROJECT_NAME"])
        let deviceName = nonEmpty(deviceConfiguration?.project.name)
        if let environmentName, let deviceName, environmentName != deviceName {
            throw M4LiveMigrationEntryError.conflictingLegacyConfiguration
        }
        guard environmentName != nil || deviceConfiguration != nil else { return nil }
        return M4ManagedProjectPresentation(
            projectName: deviceName ?? environmentName ?? "",
            showProjectName: deviceConfiguration?.project.visible ?? true
        )
    }

    private func mappedAgentProvider(_ values: [String: String]) throws -> String? {
        guard let provider = nonEmpty(values["VIBE_STICK_PROVIDER"])?.lowercased() else {
            return nil
        }
        guard ["auto", "codex", "claude"].contains(provider) else {
            throw M4LiveMigrationEntryError.invalidLegacyConfiguration
        }
        return provider
    }

    private func mappedVoiceDelivery(
        _ values: [String: String]
    ) -> M4ManagedVoiceDelivery? {
        let explicit = nonEmpty(values["VIBE_STICK_SEND_MODE"])
        let autoRaw = nonEmpty(values["VIBE_STICK_AUTO_ENTER"])
        guard explicit != nil || autoRaw != nil else { return nil }
        return M4ManagedVoiceDelivery(
            sendMode: VoiceSendMode.configured(
                explicit: explicit,
                autoEnterEnabled: booleanValue(autoRaw)
            ).rawValue
        )
    }

    private func recordingContainsActiveVoiceWork(
        _ snapshot: M4RestrictedLegacyFileSnapshot
    ) throws -> Bool {
        guard snapshot.exists else { return false }
        guard let data = snapshot.data,
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            throw M4LiveMigrationEntryError.invalidLegacyConfiguration
        }
        let status = (dictionary["status"] as? String)?.lowercased() ?? "idle"
        return ["recording", "transcribing", "pending_send"].contains(status)
    }

    private func rollbackArtifacts(
        environment: M4RestrictedLegacyFileSnapshot,
        preferences: M4RestrictedLegacyFileSnapshot,
        deviceConfiguration: M4RestrictedLegacyFileSnapshot
    ) -> [M4OfflineRollbackArtifact] {
        [
            (environment, "legacy-environment-v1.env"),
            (preferences, "legacy-app-preferences-v1.json"),
            (deviceConfiguration, "legacy-device-configuration-v1.json"),
        ].compactMap { pair in
            let (snapshot, fileName) = pair
            guard snapshot.exists, let data = snapshot.data else { return nil }
            return M4OfflineRollbackArtifact(fileName: fileName, data: data)
        }
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let cleaned = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !cleaned.isEmpty else { return nil }
        return cleaned
    }

    private func booleanValue(_ value: String?) -> Bool {
        guard let value else { return false }
        return ["1", "true", "yes", "on"].contains(value.lowercased())
    }
}

struct M4LegacyMigrationPreview: Equatable, Sendable {
    let discovery: M4LegacyDiscovery
    let plan: M4LegacyMigrationPlan
    let asrConfigurationConflict: M4RedactedASRConfigurationConflict?

    init(
        discovery: M4LegacyDiscovery,
        plan: M4LegacyMigrationPlan,
        asrConfigurationConflict: M4RedactedASRConfigurationConflict? = nil
    ) {
        self.discovery = discovery
        self.plan = plan
        self.asrConfigurationConflict = asrConfigurationConflict
    }
}

struct M4ExplicitLegacyMigrationConfirmation: Equatable, Sendable {
    let confirmedCategories: Set<M4LegacyConfigurationCategory>
    let ownedTargets: Set<M4MigrationOwnedTarget>
    let asrConfigurationSource: M4ASRConfigurationSource?

    init(
        confirmedCategories: Set<M4LegacyConfigurationCategory>,
        ownedTargets: Set<M4MigrationOwnedTarget>,
        asrConfigurationSource: M4ASRConfigurationSource? = nil
    ) {
        self.confirmedCategories = confirmedCategories
        self.ownedTargets = ownedTargets
        self.asrConfigurationSource = asrConfigurationSource
    }
}

enum M4MigrationOwnedTargetPolicy {
    static func requiredTargets(
        for categories: Set<M4LegacyConfigurationCategory>
    ) -> Set<M4MigrationOwnedTarget> {
        var targets: Set<M4MigrationOwnedTarget> = [.privateRollbackSnapshot]
        if categories.contains(where: \.containsSecret) {
            targets.insert(.versionedKeychainAccounts)
        }
        if categories.contains(where: \.requiresConfigurationWrite) {
            targets.insert(.managedConfigurationFiles)
        }
        if categories.contains(.runtimeComponents) {
            targets.insert(.existingPasteIdentity)
        }
        return targets
    }
}

protocol M4LiveMigrationTransactionStoreBuilding: Sendable {
    func makeStore(
        payload: M4OfflineMigrationPayload
    ) async throws -> any M4LegacyMigrationTransactionStoring
}

struct M4ProductionMigrationTransactionStoreBuilder: M4LiveMigrationTransactionStoreBuilding {
    func makeStore(
        payload: M4OfflineMigrationPayload
    ) async throws -> any M4LegacyMigrationTransactionStoring {
        try M4ProductionMigrationTransactionStore.live(payload: payload)
    }
}

actor M4PreparedLegacyMigrationSession: M4LegacyInspecting {
    private let source: any M4PreparedLegacyMigrationReading
    private let asrConfigurationSource: M4ASRConfigurationSource?
    private var preparedForMutation: M4PreparedLegacyMigration?
    private var inspectionCount = 0
    private var consumed = false

    init(
        source: any M4PreparedLegacyMigrationReading,
        asrConfigurationSource: M4ASRConfigurationSource? = nil
    ) {
        self.source = source
        self.asrConfigurationSource = asrConfigurationSource
    }

    func inspectRedactedLegacyState() async throws -> M4LegacyDiscovery {
        let prepared = try await source.readPreparedLegacyMigration(
            asrConfigurationSource: asrConfigurationSource
        )
        guard prepared.payload.categories == prepared.evidence.detectedCategories,
              prepared.resolvedASRConfigurationSource == asrConfigurationSource else {
            throw M4LiveMigrationEntryError.preparedStateMismatch
        }
        inspectionCount += 1
        preparedForMutation = prepared
        return prepared.discovery
    }

    func consumePayloadAfterDoublePreflight() throws -> M4OfflineMigrationPayload {
        guard inspectionCount == 2, !consumed, let preparedForMutation else {
            throw M4LiveMigrationEntryError.doublePreflightNotCompleted
        }
        consumed = true
        self.preparedForMutation = nil
        return try preparedForMutation.payload.validated()
    }
}

actor M4DeferredLiveMigrationTransactionStore: M4LegacyMigrationTransactionStoring {
    private let session: M4PreparedLegacyMigrationSession
    private let builder: any M4LiveMigrationTransactionStoreBuilding
    private var store: (any M4LegacyMigrationTransactionStoring)?

    init(
        session: M4PreparedLegacyMigrationSession,
        builder: any M4LiveMigrationTransactionStoreBuilding
    ) {
        self.session = session
        self.builder = builder
    }

    func preparePrivateRollback(for categories: [M4LegacyConfigurationCategory]) async throws {
        guard store == nil else { throw M4LiveMigrationEntryError.transactionStoreAlreadyCreated }
        let payload = try await session.consumePayloadAfterDoublePreflight()
        let created = try await builder.makeStore(payload: payload)
        store = created
        try await created.preparePrivateRollback(for: categories)
    }

    func stageVersionedKeychainItems(
        for categories: [M4LegacyConfigurationCategory]
    ) async throws {
        try await requiredStore().stageVersionedKeychainItems(for: categories)
    }

    func stageConfigurationFiles(for categories: [M4LegacyConfigurationCategory]) async throws {
        try await requiredStore().stageConfigurationFiles(for: categories)
    }

    func preservePasteIdentity() async throws {
        try await requiredStore().preservePasteIdentity()
    }

    func validateStagedState() async throws -> M4StagedMigrationValidation {
        try await requiredStore().validateStagedState()
    }

    func atomicallyCommitConfiguration() async throws {
        try await requiredStore().atomicallyCommitConfiguration()
    }

    func retainLegacyFallback() async throws {
        try await requiredStore().retainLegacyFallback()
    }

    func restorePreviousStateAndDiscardStaging() async throws {
        guard let store else { return }
        try await store.restorePreviousStateAndDiscardStaging()
    }

    private func requiredStore() throws -> any M4LegacyMigrationTransactionStoring {
        guard let store else { throw M4LiveMigrationEntryError.transactionStoreUnavailable }
        return store
    }
}

struct M4ExplicitLegacyMigrationEntry: Sendable {
    private let source: any M4ExplicitLegacyMigrationReading
    private let builder: any M4LiveMigrationTransactionStoreBuilding

    init(
        source: any M4ExplicitLegacyMigrationReading,
        builder: any M4LiveMigrationTransactionStoreBuilding
    ) {
        self.source = source
        self.builder = builder
    }

    static func production(
        runtimeFacts: any M4LegacyRuntimeFactsReading
    ) throws -> Self {
        let allowlist = try M4LegacyFileAllowlist(
            supportDirectory: SupportPaths.supportDirectory
        )
        return Self(
            source: M4RestrictedLegacyMigrationSource(
                files: M4FoundationRestrictedLegacyFileReader(allowlist: allowlist),
                credentials: M4SecurityRestrictedLegacyCredentialReader(),
                runtime: runtimeFacts
            ),
            builder: M4ProductionMigrationTransactionStoreBuilder()
        )
    }

    func discover() async throws -> M4LegacyMigrationPreview {
        do {
            let redacted = try await source.readRedactedLegacyDiscovery()
            let evidence = redacted.evidence
            let discovery = M4LegacyDiscovery(
                detectedCategories: evidence.detectedCategories,
                legacyFileExists: evidence.legacyFileExists,
                legacyFilePermissionsArePrivate: evidence.legacyFilePermissionsArePrivate,
                unknownRuntimeOwnerDetected: evidence.runtimeOwnershipIsUnknown,
                activeVoiceWorkDetected: evidence.activeVoiceWorkExists
            )
            return M4LegacyMigrationPreview(
                discovery: discovery,
                plan: M4LegacyMigrationPlanner.make(from: discovery),
                asrConfigurationConflict: redacted.asrConfigurationConflict
            )
        } catch let error as M4LiveMigrationEntryError {
            throw error
        } catch {
            throw M4LiveMigrationEntryError.discoveryFailed
        }
    }

    func migrate(
        preview: M4LegacyMigrationPreview,
        confirmation: M4ExplicitLegacyMigrationConfirmation
    ) async throws -> M4LegacyMigrationReceiptSummary {
        guard preview.plan.canOfferImport else {
            throw M4LiveMigrationEntryError.migrationNotOffered
        }
        let sourceMatchesPreview: Bool
        if let conflict = preview.asrConfigurationConflict {
            sourceMatchesPreview = confirmation.asrConfigurationSource.map {
                conflict.availableSources.contains($0)
            } == true
        } else {
            sourceMatchesPreview = confirmation.asrConfigurationSource == nil
        }
        let requiredTargets = M4MigrationOwnedTargetPolicy.requiredTargets(
            for: preview.discovery.detectedCategories
        )
        guard confirmation.confirmedCategories == preview.discovery.detectedCategories,
              confirmation.ownedTargets == requiredTargets,
              sourceMatchesPreview else {
            throw M4LiveMigrationEntryError.confirmationMismatch
        }

        let session = M4PreparedLegacyMigrationSession(
            source: source,
            asrConfigurationSource: confirmation.asrConfigurationSource
        )
        let store = M4DeferredLiveMigrationTransactionStore(
            session: session,
            builder: builder
        )
        let coordinator = M4LegacyMigrationCoordinator(inspector: session, store: store)
        return try await coordinator.migrate(
            authorization: M4LegacyMigrationAuthorization(
                confirmedDiscovery: preview.discovery,
                confirmedCategories: confirmation.confirmedCategories,
                ownedTargets: confirmation.ownedTargets
            )
        )
    }
}

enum M4LiveMigrationEntryError: Error, Equatable, Sendable {
    case unsafeFileScope
    case symbolicLinkInLegacyScope
    case legacyFileIsNotRegular
    case legacyFileTooLarge
    case legacyFileReadFailed
    case legacyFileChangedWhileReading
    case unsafeCredentialScope
    case legacyCredentialReadFailed
    case invalidLegacyEncoding
    case invalidLegacyCredential
    case invalidLegacyConfiguration
    case conflictingLegacyConfiguration
    case asrConfigurationSourceSelectionRequired
    case asrConfigurationSourceSelectionMismatch
    case missingRequiredCredential
    case preparedStateMismatch
    case discoveryFailed
    case migrationNotOffered
    case confirmationMismatch
    case doublePreflightNotCompleted
    case transactionStoreAlreadyCreated
    case transactionStoreUnavailable
}
