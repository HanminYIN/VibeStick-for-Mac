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

    static var bridgeLaunchAgent: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.vibestick.bridge.plist")
    }

    static var hudLaunchAgent: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.vibestick.hud.plist")
    }

    static var bridgeApp: URL {
        supportDirectory.appendingPathComponent("VibeStick Bridge.app", isDirectory: true)
    }

    static var bridgeExecutable: URL {
        bridgeApp.appendingPathComponent("Contents/MacOS/VibeStickBridge")
    }

    static var hudApp: URL {
        supportDirectory.appendingPathComponent("VibeStick HUD.app", isDirectory: true)
    }

    static var hudExecutable: URL {
        hudApp.appendingPathComponent("Contents/MacOS/VibeStickHUD")
    }

    static var pasteApp: URL {
        supportDirectory.appendingPathComponent("VibeStick Paste.app", isDirectory: true)
    }

    static var pasteExecutable: URL {
        pasteApp.appendingPathComponent("Contents/MacOS/VibeStickPaste")
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

struct KeychainStore: SecretStoring, Sendable {
    private let service = "io.github.hanminyin.vibestick"

    func contains(_ key: KeychainSecret) -> Bool {
        do {
            return try read(key) != nil
        } catch {
            return false
        }
    }

    func read(_ key: KeychainSecret) throws -> Data? {
        var query = baseQuery(for: key)
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
        let query = baseQuery(for: key)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updateStatus = SecItemUpdate(
                query as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
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
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    private func baseQuery(for key: KeychainSecret) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
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
    private let keychainStore: any SecretStoring

    init(
        fileManager: FileManager = .default,
        environmentFile: URL = SupportPaths.legacyEnvironmentFile,
        keychainStore: any SecretStoring = KeychainStore()
    ) {
        self.fileManager = fileManager
        self.environmentFile = environmentFile
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

        let legacy = LegacyConfigurationSummary(
            legacyFileExists: exists,
            asrConfigurationDetected: asrConfigurationDetected,
            asrProvider: provider,
            autoEnterEnabled: booleanValue(values["VIBE_STICK_AUTO_ENTER"]),
            projectName: nonEmpty(values["VIBE_STICK_PROJECT_NAME"]),
            containsLegacySecrets: hasSecrets,
            legacyFileIsOverexposed: isOverexposed
        )
        let keychain = KeychainSummary(
            bridgeTokenStored: keychainStore.contains(.bridgeToken),
            asrKeyStored: keychainStore.contains(.asrAPIKey)
        )
        return ConfigurationInspection(legacy: legacy, keychain: keychain)
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
