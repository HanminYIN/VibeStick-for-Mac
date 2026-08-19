import AppKit
import Foundation
import Security
import ServiceManagement

enum SupportPaths {
    static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/VibeStick", isDirectory: true)
    }

    static var preferencesFile: URL {
        supportDirectory.appendingPathComponent("config-v1.json")
    }

    static var legacyEnvironmentFile: URL {
        supportDirectory.appendingPathComponent(".env")
    }

    static var managedRuntimeFile: URL {
        supportDirectory.appendingPathComponent("managed-runtime-v1.json")
    }

    static var deviceRegistryFile: URL {
        supportDirectory.appendingPathComponent("devices-v1.json")
    }

    static var deviceConfigurationFile: URL {
        supportDirectory.appendingPathComponent("device-config-v1.json")
    }

    static var bridgeIdentityFile: URL {
        supportDirectory.appendingPathComponent("bridge-identity-v1.json")
    }

    static var bridgeLaunchAgent: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.vibestick.bridge.plist")
    }

    static var hudLaunchAgent: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.vibestick.hud.plist")
    }

    static var bridgeApp: URL {
        componentsDirectory.appendingPathComponent("VibeStick Bridge.app", isDirectory: true)
    }

    static var bridgeExecutable: URL {
        bridgeApp.appendingPathComponent("Contents/MacOS/VibeStickBridge")
    }

    static var hudApp: URL {
        componentsDirectory.appendingPathComponent("VibeStick HUD.app", isDirectory: true)
    }

    static var hudExecutable: URL {
        hudApp.appendingPathComponent("Contents/MacOS/VibeStickHUD")
    }

    static var pasteApp: URL {
        componentsDirectory.appendingPathComponent("VibeStick Paste.app", isDirectory: true)
    }

    static var pasteExecutable: URL {
        pasteApp.appendingPathComponent("Contents/MacOS/VibeStickPaste")
    }

    private static var componentsDirectory: URL {
        supportDirectory.appendingPathComponent("Components.noindex", isDirectory: true)
    }

    static var recordingFile: URL {
        supportDirectory.appendingPathComponent("recording.json")
    }
}

actor PreferencesStore {
    private let fileManager: FileManager
    private let fileURL: URL

    init(
        fileManager: FileManager = .default,
        fileURL: URL = SupportPaths.preferencesFile
    ) {
        self.fileManager = fileManager
        self.fileURL = fileURL
    }

    func load() -> AppConfiguration {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(AppConfiguration.self, from: data),
              decoded.schemaVersion == AppConfiguration.currentSchemaVersion else {
            return .standard
        }
        return decoded
    }

    func save(_ configuration: AppConfiguration) throws {
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let data = try JSONEncoder.vibeStick.encode(configuration)
        let temporaryURL = directory.appendingPathComponent(".config-v1.json.tmp-" + UUID().uuidString)
        try data.write(to: temporaryURL, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporaryURL.path)

        if fileManager.fileExists(atPath: fileURL.path) {
            _ = try fileManager.replaceItemAt(fileURL, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: fileURL)
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

private extension JSONEncoder {
    static var vibeStick: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

protocol SecretStoring: Sendable {
    func contains(_ key: KeychainSecret) -> Bool
}

enum KeychainAccessPolicy {
    static let asrAdditionalTrustedApplicationPaths = ["/usr/bin/security"]

    static func existingItemUpdateAttributes(data: Data) -> [String: Any] {
        [kSecValueData as String: data]
    }

    static func makeASRAccess() throws -> SecAccess {
        try makeAccess(
            label: "VibeStick ASR API Key",
            additionalTrustedApplicationPaths: asrAdditionalTrustedApplicationPaths
        )
    }

    static func makeManagedRuntimeAccess(label: String) throws -> SecAccess {
        try makeAccess(
            label: label,
            additionalTrustedApplicationPaths: asrAdditionalTrustedApplicationPaths
        )
    }

    private static func makeAccess(
        label: String,
        additionalTrustedApplicationPaths: [String]
    ) throws -> SecAccess {
        var trustedApplications: [SecTrustedApplication] = []
        var currentApplication: SecTrustedApplication?
        var status = SecTrustedApplicationCreateFromPath(nil, &currentApplication)
        guard status == errSecSuccess, let currentApplication else {
            throw KeychainError(status: status)
        }
        trustedApplications.append(currentApplication)

        for path in additionalTrustedApplicationPaths {
            var trustedApplication: SecTrustedApplication?
            status = path.withCString {
                SecTrustedApplicationCreateFromPath($0, &trustedApplication)
            }
            guard status == errSecSuccess, let trustedApplication else {
                throw KeychainError(status: status)
            }
            trustedApplications.append(trustedApplication)
        }

        var access: SecAccess?
        status = SecAccessCreate(
            label as CFString,
            trustedApplications as CFArray,
            &access
        )
        guard status == errSecSuccess, let access else {
            throw KeychainError(status: status)
        }
        return access
    }
}

struct KeychainStore: SecretStoring, Sendable {
    private let service = "io.github.hanminyin.vibestick"

    func contains(_ key: KeychainSecret) -> Bool {
        var query = baseQuery(account: key.rawValue)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    func read(_ key: KeychainSecret) throws -> Data? {
        try read(account: key.rawValue)
    }

    func read(account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw KeychainError(status: status)
        }
        return result as? Data
    }

    func write(_ data: Data, for key: KeychainSecret) throws {
        let access = key == .asrAPIKey
            ? try KeychainAccessPolicy.makeASRAccess()
            : nil
        try write(data, account: key.rawValue, access: access)
    }

    func write(_ data: Data, account: String) throws {
        try write(data, account: account, access: nil)
    }

    private func write(_ data: Data, account: String, access: SecAccess?) throws {
        let query = baseQuery(account: account)
        var attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        if let access {
            attributes[kSecAttrAccess as String] = access
        }
        let status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updateStatus = SecItemUpdate(
                query as CFDictionary,
                KeychainAccessPolicy.existingItemUpdateAttributes(data: data) as CFDictionary
            )
            guard updateStatus == errSecSuccess else {
                throw KeychainError(status: updateStatus)
            }
            return
        }
        guard status == errSecSuccess else {
            throw KeychainError(status: status)
        }
    }

    func delete(_ key: KeychainSecret) throws {
        try delete(account: key.rawValue)
    }

    func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

struct KeychainError: LocalizedError {
    let status: OSStatus

    var errorDescription: String? {
        SecCopyErrorMessageString(status, nil) as String?
            ?? "Keychain error " + String(status)
    }
}

actor ConfigurationInspector {
    private let fileManager: FileManager
    private let environmentFile: URL
    private let recordingFile: URL
    private let keychainStore: any SecretStoring

    init(
        fileManager: FileManager = .default,
        environmentFile: URL = SupportPaths.legacyEnvironmentFile,
        recordingFile: URL? = nil,
        keychainStore: any SecretStoring = KeychainStore()
    ) {
        self.fileManager = fileManager
        self.environmentFile = environmentFile
        self.recordingFile = recordingFile
            ?? environmentFile.deletingLastPathComponent().appendingPathComponent("recording.json")
        self.keychainStore = keychainStore
    }

    func inspect() -> ConfigurationInspection {
        let exists = fileManager.fileExists(atPath: environmentFile.path)
        let contents = (try? String(contentsOf: environmentFile, encoding: .utf8)) ?? ""
        let values = LegacyEnvironmentParser.parse(contents)
        let secretKeys = [
            "VIBE_STICK_BRIDGE_TOKEN",
            "VIBE_STICK_ASR_API_KEY",
            "VIBE_STICK_GROQ_API_KEY",
            "CLAUDE_CODE_OAUTH_TOKEN",
        ]
        let hasSecrets = secretKeys.contains { !(values[$0] ?? "").isEmpty }

        let attributes = try? fileManager.attributesOfItem(atPath: environmentFile.path)
        let permissions = (attributes?[.posixPermissions] as? NSNumber)?.intValue
        let isOverexposed = exists && ((permissions ?? 0o644) & 0o077) != 0

        let provider = nonEmpty(values["VIBE_STICK_ASR_PROVIDER"])
            ?? (nonEmpty(values["VIBE_STICK_GROQ_API_KEY"]) == nil ? nil : "groq")
        let asrConfigurationDetected = nonEmpty(values["VIBE_STICK_TRANSCRIBE_CMD"]) != nil
            || nonEmpty(values["VIBE_STICK_ASR_API_KEY"]) != nil
            || nonEmpty(values["VIBE_STICK_GROQ_API_KEY"]) != nil

        let autoEnterEnabled = booleanValue(values["VIBE_STICK_AUTO_ENTER"])
        let voiceSendMode = VoiceSendMode.configured(
            explicit: values["VIBE_STICK_SEND_MODE"],
            autoEnterEnabled: autoEnterEnabled
        )
        let legacy = LegacyConfigurationSummary(
            legacyFileExists: exists,
            asrConfigurationDetected: asrConfigurationDetected,
            asrProvider: provider,
            autoEnterEnabled: autoEnterEnabled,
            voiceSendMode: voiceSendMode,
            projectName: nonEmpty(values["VIBE_STICK_PROJECT_NAME"]),
            containsLegacySecrets: hasSecrets,
            legacyFileIsOverexposed: isOverexposed
        )
        let legacyKeychain = LegacyKeychainSummary(
            bridgeTokenStored: keychainStore.contains(.bridgeToken),
            asrKeyStored: keychainStore.contains(.asrAPIKey)
        )
        return ConfigurationInspection(
            legacy: legacy,
            legacyKeychain: legacyKeychain,
            voice: inspectVoiceInteraction(fallbackSendMode: voiceSendMode)
        )
    }

    private func inspectVoiceInteraction(fallbackSendMode: VoiceSendMode) -> VoiceInteractionSummary {
        guard let data = try? Data(contentsOf: recordingFile),
              let object = try? JSONSerialization.jsonObject(with: data),
              let payload = object as? [String: Any] else {
            return VoiceInteractionSummary(
                status: "idle",
                pasted: false,
                interactionVersion: 1,
                sendMode: fallbackSendMode,
                stoppedAt: nil
            )
        }
        return VoiceInteractionSummary(
            status: payload["status"] as? String ?? "idle",
            pasted: payload["pasted"] as? Bool == true,
            interactionVersion: payload["interaction_version"] as? Int ?? 1,
            sendMode: VoiceSendMode.configured(
                explicit: payload["send_mode"] as? String,
                autoEnterEnabled: fallbackSendMode == .autoSend
            ),
            stoppedAt: nonEmpty(payload["stopped_at"] as? String)
        )
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

enum M4ManagedRuntimeStatusInspectionError: Error, Equatable, Sendable {
    case unsafeConfigurationFile
    case oversizedConfigurationFile
}

protocol M4ManagedRuntimeConfigurationReading: Sendable {
    func readManagedRuntimeConfiguration() async throws -> Data?
}

protocol M4ManagedCredentialPresenceChecking: Sendable {
    func contains(_ reference: M4VersionedCredentialReference) async throws -> Bool
}

struct M4FoundationManagedRuntimeConfigurationReader:
    M4ManagedRuntimeConfigurationReading,
    Sendable
{
    private static let maximumByteCount = 1_048_576

    private let fileURL: URL

    init(fileURL: URL = SupportPaths.managedRuntimeFile) {
        self.fileURL = fileURL
    }

    func readManagedRuntimeConfiguration() throws -> Data? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
        let type = attributes[.type] as? FileAttributeType
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        let byteCount = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard type == .typeRegular,
              let permissions,
              permissions & 0o077 == 0 else {
            throw M4ManagedRuntimeStatusInspectionError.unsafeConfigurationFile
        }
        guard byteCount > 0, byteCount <= Self.maximumByteCount else {
            throw M4ManagedRuntimeStatusInspectionError.oversizedConfigurationFile
        }
        let data = try Data(contentsOf: fileURL)
        guard data.count == byteCount else {
            throw M4ManagedRuntimeStatusInspectionError.unsafeConfigurationFile
        }
        return data
    }
}

extension M4SecurityVersionedGenericPasswordClient: M4ManagedCredentialPresenceChecking {}

actor M4ManagedRuntimeStatusInspector {
    private let configurationReader: any M4ManagedRuntimeConfigurationReading
    private let credentialPresenceChecker: any M4ManagedCredentialPresenceChecking

    init(
        configurationReader: any M4ManagedRuntimeConfigurationReading =
            M4FoundationManagedRuntimeConfigurationReader(),
        credentialPresenceChecker: any M4ManagedCredentialPresenceChecking =
            M4SecurityVersionedGenericPasswordClient()
    ) {
        self.configurationReader = configurationReader
        self.credentialPresenceChecker = credentialPresenceChecker
    }

    func inspect() async -> M4ManagedRuntimeSummary {
        let data: Data
        do {
            guard let loaded = try await configurationReader.readManagedRuntimeConfiguration() else {
                return .empty
            }
            data = loaded
        } catch {
            return M4ManagedRuntimeSummary(
                configurationState: .unavailable,
                bridgeCredentialState: .notReferenced,
                asrCredentialState: .notReferenced
            )
        }

        let configuration: M4ManagedRuntimeConfiguration
        do {
            configuration = try JSONDecoder().decode(
                M4ManagedRuntimeConfiguration.self,
                from: data
            ).validated()
        } catch {
            return M4ManagedRuntimeSummary(
                configurationState: .invalid,
                bridgeCredentialState: .notReferenced,
                asrCredentialState: .notReferenced
            )
        }

        return M4ManagedRuntimeSummary(
            configurationState: .validated,
            bridgeCredentialState: await credentialState(
                for: .bridgeToken,
                in: configuration
            ),
            asrCredentialState: await credentialState(
                for: .asrAPIKey,
                in: configuration
            )
        )
    }

    private func credentialState(
        for purpose: M4CredentialPurpose,
        in configuration: M4ManagedRuntimeConfiguration
    ) async -> M4ManagedCredentialState {
        guard let reference = configuration.credentialReference(for: purpose) else {
            return .notReferenced
        }
        do {
            return try await credentialPresenceChecker.contains(reference) ? .stored : .missing
        } catch {
            return .unavailable
        }
    }
}

protocol M4ManagedASRSettingsManaging: Sendable {
    func loadConfigurationIfManaged() async throws -> ASRConfiguration?
    func saveIfManaged(_ configuration: ASRConfiguration, apiKey: String) async throws -> Bool
    func storedAPIKeyIfManaged() async throws -> M4ManagedASRAPIKeyLookup
    func deleteAPIKeyIfManaged() async throws -> Bool
}

struct M4ManagedASRAPIKeyLookup: Equatable, Sendable {
    let isManaged: Bool
    let apiKey: String?

    static let legacy = M4ManagedASRAPIKeyLookup(isManaged: false, apiKey: nil)
}

enum M4ManagedASRSettingsError: LocalizedError {
    case unavailable
    case missingAPIKey

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "受管语音设置无法安全更新；原配置和凭据已尽可能恢复。"
        case .missingAPIKey:
            "受管云端语音供应方需要一个保存在 macOS 钥匙串中的 API Key。"
        }
    }
}

actor M4ManagedASRSettingsStore: M4ManagedASRSettingsManaging {
    private static let maximumConfigurationBytes = 1_048_576
    private static let maximumCredentialBytes = 65_536

    private let configurationURL: URL
    private let credentialClient: any M4VersionedGenericPasswordAccess

    init(
        configurationURL: URL = SupportPaths.managedRuntimeFile,
        credentialClient: any M4VersionedGenericPasswordAccess =
            M4SecurityVersionedGenericPasswordClient()
    ) {
        self.configurationURL = configurationURL
        self.credentialClient = credentialClient
    }

    func loadConfigurationIfManaged() throws -> ASRConfiguration? {
        guard let managed = try loadManagedConfiguration() else { return nil }
        guard let asr = managed.asr,
              let provider = ASRProvider(rawValue: asr.provider) else { return nil }
        return try ASRConfiguration(
            provider: provider,
            baseURL: asr.baseURL,
            model: asr.model,
            language: asr.language,
            localCommand: asr.localCommand
        ).validated()
    }

    func saveIfManaged(_ configuration: ASRConfiguration, apiKey: String) async throws -> Bool {
        guard let original = try loadManagedConfiguration() else { return false }
        let requested = try configuration.validated()
        let asrReference = M4VersionedCredentialReference.managed(.asrAPIKey)
        let previousCredential = requested.provider.isCloud
            ? try await credentialClient.read(asrReference)
            : nil
        let suppliedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let suppliedCredential = Data(suppliedKey.utf8)
        var references = original.credentialReferences.filter { $0.purpose != .asrAPIKey }
        var replacementCredential: Data?

        if requested.provider.isCloud {
            let effectiveCredential = suppliedCredential.isEmpty
                ? previousCredential ?? Data()
                : suppliedCredential
            guard !effectiveCredential.isEmpty,
                  effectiveCredential.count <= Self.maximumCredentialBytes else {
                throw M4ManagedASRSettingsError.missingAPIKey
            }
            references.append(asrReference)
            if !suppliedCredential.isEmpty, suppliedCredential != previousCredential {
                replacementCredential = suppliedCredential
            }
        }

        let updated = try M4ManagedRuntimeConfiguration(
            schemaVersion: original.schemaVersion,
            credentialReferences: references,
            asr: M4ManagedASRConfiguration(
                provider: requested.provider.rawValue,
                baseURL: requested.baseURL,
                model: requested.model,
                language: requested.language,
                localCommand: requested.localCommand
            ),
            agentProvider: original.agentProvider,
            projectPresentation: original.projectPresentation,
            voiceDelivery: original.voiceDelivery,
            soundEnabled: original.soundEnabled
        ).validated()

        var credentialWasReplaced = false
        do {
            if let replacementCredential {
                try await replaceCredential(
                    asrReference,
                    previous: previousCredential,
                    replacement: replacementCredential
                )
                credentialWasReplaced = true
            }
            try writeManagedConfiguration(updated)
            return true
        } catch {
            if credentialWasReplaced {
                try? await restoreCredential(asrReference, previous: previousCredential)
            }
            if let error = error as? M4ManagedASRSettingsError { throw error }
            throw M4ManagedASRSettingsError.unavailable
        }
    }

    func storedAPIKeyIfManaged() async throws -> M4ManagedASRAPIKeyLookup {
        guard let configuration = try loadManagedConfiguration() else { return .legacy }
        let reference = M4VersionedCredentialReference.managed(.asrAPIKey)
        guard configuration.credentialReference(for: .asrAPIKey) != nil else {
            return M4ManagedASRAPIKeyLookup(isManaged: true, apiKey: nil)
        }
        let data = try await credentialClient.read(reference)
        guard let data,
              !data.isEmpty,
              data.count <= Self.maximumCredentialBytes,
              let value = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return M4ManagedASRAPIKeyLookup(isManaged: true, apiKey: nil)
        }
        return M4ManagedASRAPIKeyLookup(isManaged: true, apiKey: value)
    }

    func deleteAPIKeyIfManaged() async throws -> Bool {
        guard try loadManagedConfiguration() != nil else { return false }
        try await credentialClient.delete(.managed(.asrAPIKey))
        return true
    }

    private func loadManagedConfiguration() throws -> M4ManagedRuntimeConfiguration? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: configurationURL.path) else { return nil }
        do {
            let attributes = try fileManager.attributesOfItem(atPath: configurationURL.path)
            let type = attributes[.type] as? FileAttributeType
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
            let byteCount = (attributes[.size] as? NSNumber)?.intValue ?? 0
            guard type == .typeRegular,
                  let permissions,
                  permissions & 0o077 == 0,
                  byteCount > 0,
                  byteCount <= Self.maximumConfigurationBytes else {
                throw M4ManagedASRSettingsError.unavailable
            }
            let data = try Data(contentsOf: configurationURL)
            guard data.count == byteCount else { throw M4ManagedASRSettingsError.unavailable }
            return try JSONDecoder().decode(
                M4ManagedRuntimeConfiguration.self,
                from: data
            ).validated()
        } catch let error as M4ManagedASRSettingsError {
            throw error
        } catch {
            throw M4ManagedASRSettingsError.unavailable
        }
    }

    private func writeManagedConfiguration(_ configuration: M4ManagedRuntimeConfiguration) throws {
        let fileManager = FileManager.default
        let directory = configurationURL.deletingLastPathComponent()
        let temporaryURL = directory.appendingPathComponent(
            ".managed-runtime-v1.\(UUID().uuidString).tmp"
        )
        defer { try? fileManager.removeItem(at: temporaryURL) }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(configuration).write(to: temporaryURL, options: .atomic)
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: temporaryURL.path
            )
            _ = try fileManager.replaceItemAt(configurationURL, withItemAt: temporaryURL)
        } catch {
            throw M4ManagedASRSettingsError.unavailable
        }
    }

    private func replaceCredential(
        _ reference: M4VersionedCredentialReference,
        previous: Data?,
        replacement: Data
    ) async throws {
        if previous != nil {
            try await credentialClient.delete(reference)
        }
        do {
            try await credentialClient.add(replacement, for: reference)
        } catch {
            if let previous {
                try? await credentialClient.add(previous, for: reference)
            }
            throw M4ManagedASRSettingsError.unavailable
        }
    }

    private func restoreCredential(
        _ reference: M4VersionedCredentialReference,
        previous: Data?
    ) async throws {
        try await credentialClient.delete(reference)
        if let previous {
            try await credentialClient.add(previous, for: reference)
        }
    }
}

actor LoginItemController {
    func isEnabled() -> Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

@MainActor
enum SystemSettingsOpener {
    static func openAccessibility() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openLoginItems() {
        open("x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
    }

    static func openSupportDirectory() {
        NSWorkspace.shared.open(SupportPaths.supportDirectory)
    }

    private static func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }
}
