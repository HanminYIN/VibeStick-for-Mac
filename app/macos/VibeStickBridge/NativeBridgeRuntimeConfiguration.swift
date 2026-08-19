import Darwin
import Foundation

struct NativeBridgeRuntimeConfigurationError: Error, Equatable, CustomStringConvertible {
    let code: String

    var description: String { code }

    static func unavailable(_ code: String = "managed-runtime-unavailable") -> Self {
        NativeBridgeRuntimeConfigurationError(code: code)
    }
}

enum NativeBridgeRuntimeMode: String, Equatable {
    case managed
    case legacy
}

struct NativeManagedASRConfiguration: Equatable {
    let provider: String
    let baseURL: String
    let model: String
    let language: String
    let localCommand: String

    var requiresCredential: Bool { provider != "local-command" }

    func cloudConfiguration(
        apiKey: String,
        attempts: Int = 3,
        timeout: TimeInterval = 30
    ) -> NativeASRConfiguration? {
        guard requiresCredential else { return nil }
        return NativeASRConfiguration.normalized(
            provider: provider,
            baseURL: baseURL,
            apiKey: apiKey,
            model: model,
            language: language,
            attempts: attempts,
            timeout: timeout
        )
    }
}

struct NativeManagedProjectPresentation: Equatable {
    let projectName: String
    let showProjectName: Bool

    var jsonObject: [String: Any] {
        ["projectName": projectName, "showProjectName": showProjectName]
    }
}

struct NativeResolvedRuntimeConfiguration: Equatable {
    let mode: NativeBridgeRuntimeMode
    let bridgeToken: String
    let asrAPIKey: String
    let asr: NativeManagedASRConfiguration?
    let agentProvider: String
    let projectPresentation: NativeManagedProjectPresentation?
    let sendMode: NativeVoiceSendMode
    let soundEnabled: Bool?

    var cloudASRConfiguration: NativeASRConfiguration? {
        asr?.cloudConfiguration(apiKey: asrAPIKey)
    }

    var localTranscriptionCommand: String? {
        guard let asr, asr.provider == "local-command" else { return nil }
        let command = asr.localCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        return command.isEmpty ? nil : command
    }
}

protocol NativeManagedCredentialReading {
    func read(service: String, account: String) throws -> String
}

struct NativeSecurityCommandResult: Sendable {
    let status: Int32
    let standardOutput: Data
}

struct NativeFixedKeychainCredentialReader {
    typealias SecurityCommand = @Sendable ([String]) -> NativeSecurityCommandResult

    static let maximumCredentialBytes = 65_536
    static let securityExecutable = "/usr/bin/security"

    let allowedAccounts: Set<String>
    let errorCode: String
    let runSecurity: SecurityCommand

    func read(service: String, account: String) throws -> String {
        guard service == NativeManagedRuntimeParser.keychainService,
              allowedAccounts.contains(account) else {
            throw NativeBridgeRuntimeConfigurationError.unavailable(errorCode)
        }

        let result = runSecurity([
            "find-generic-password",
            "-s", service,
            "-a", account,
            "-w",
        ])
        guard result.status == 0,
              let value = normalized(result.standardOutput) else {
            throw NativeBridgeRuntimeConfigurationError.unavailable(errorCode)
        }
        return value
    }

    private func normalized(_ data: Data?) -> String? {
        guard let data,
              !data.isEmpty,
              data.count <= Self.maximumCredentialBytes,
              let value = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    static func runSecurity(arguments: [String]) -> NativeSecurityCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: securityExecutable)
        process.arguments = arguments
        let standardOutput = Pipe()
        process.standardOutput = standardOutput
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return NativeSecurityCommandResult(status: -1, standardOutput: Data())
        }
        let data = standardOutput.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return NativeSecurityCommandResult(
            status: process.terminationStatus,
            standardOutput: data
        )
    }
}

struct NativeManagedKeychainCredentialReader: NativeManagedCredentialReading {
    private let reader: NativeFixedKeychainCredentialReader

    init(
        runSecurity: @escaping NativeFixedKeychainCredentialReader.SecurityCommand =
            NativeFixedKeychainCredentialReader.runSecurity
    ) {
        reader = NativeFixedKeychainCredentialReader(
            allowedAccounts: Set(NativeManagedRuntimeParser.managedAccounts.values),
            errorCode: "managed-credential-unavailable",
            runSecurity: runSecurity
        )
    }

    func read(service: String, account: String) throws -> String {
        try reader.read(service: service, account: account)
    }
}

struct NativeLegacyASRKeychainReader: NativeManagedCredentialReading {
    private let reader: NativeFixedKeychainCredentialReader

    init(
        runSecurity: @escaping NativeFixedKeychainCredentialReader.SecurityCommand =
            NativeFixedKeychainCredentialReader.runSecurity
    ) {
        reader = NativeFixedKeychainCredentialReader(
            allowedAccounts: ["asr-api-key"],
            errorCode: "legacy-credential-unavailable",
            runSecurity: runSecurity
        )
    }

    func read(service: String, account: String) throws -> String {
        try reader.read(service: service, account: account)
    }
}

enum NativeManagedRuntimeParser {
    static let schemaVersion = 1
    static let keychainStorage = "macos-keychain"
    static let keychainService = "io.github.hanminyin.vibestick"
    static let managedAccounts = [
        "bridge-token": "bridge-token-v1",
        "asr-api-key": "asr-api-key-v1",
    ]

    static func parse(
        _ data: Data,
        credentialReader: NativeManagedCredentialReading
    ) throws -> NativeResolvedRuntimeConfiguration {
        guard let value = try? JSONSerialization.jsonObject(with: data),
              let document = value as? [String: Any],
              integer(document["schemaVersion"]) == schemaVersion else {
            throw error("unsupported-managed-configuration")
        }
        let references = try credentialReferences(document["credentialReferences"])
        let asr = try parseASR(document["asr"])
        let agentProvider = try parseAgentProvider(document["agentProvider"])
        let project = try parseProjectPresentation(document["projectPresentation"])
        let sendMode = try parseSendMode(document["voiceDelivery"])
        let soundEnabled = try optionalBoolean(document, key: "soundEnabled")
        let bridgeToken = try resolve(
            purpose: "bridge-token",
            references: references,
            credentialReader: credentialReader,
            missingError: "missing-bridge-credential"
        )
        guard !NativeBridgeSecurity.placeholderTokens.contains(bridgeToken.lowercased()) else {
            throw error("missing-bridge-credential")
        }
        let asrAPIKey: String
        if asr?.requiresCredential == true {
            asrAPIKey = try resolve(
                purpose: "asr-api-key",
                references: references,
                credentialReader: credentialReader,
                missingError: "missing-asr-credential"
            )
            guard asr?.cloudConfiguration(apiKey: asrAPIKey) != nil else {
                throw error("invalid-asr-configuration")
            }
        } else {
            asrAPIKey = ""
        }
        return NativeResolvedRuntimeConfiguration(
            mode: .managed,
            bridgeToken: bridgeToken,
            asrAPIKey: asrAPIKey,
            asr: asr,
            agentProvider: agentProvider ?? "auto",
            projectPresentation: project,
            sendMode: sendMode ?? .pasteOnly,
            soundEnabled: soundEnabled
        )
    }

    private static func credentialReferences(_ raw: Any?) throws -> [String: String] {
        guard let items = raw as? [Any] else {
            throw error("invalid-credential-references")
        }
        var references: [String: String] = [:]
        for rawItem in items {
            guard let item = rawItem as? [String: Any],
                  integer(item["schemaVersion"]) == schemaVersion,
                  item["storage"] as? String == keychainStorage,
                  item["service"] as? String == keychainService,
                  let purpose = item["purpose"] as? String,
                  let expectedAccount = managedAccounts[purpose],
                  item["account"] as? String == expectedAccount,
                  references[purpose] == nil else {
                throw error("invalid-credential-reference")
            }
            references[purpose] = expectedAccount
        }
        return references
    }

    private static func resolve(
        purpose: String,
        references: [String: String],
        credentialReader: NativeManagedCredentialReading,
        missingError: String
    ) throws -> String {
        guard let account = references[purpose] else { throw error(missingError) }
        do {
            let value = try credentialReader.read(service: keychainService, account: account)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { throw error(missingError) }
            return value
        } catch {
            throw self.error(missingError)
        }
    }

    private static func parseASR(_ raw: Any?) throws -> NativeManagedASRConfiguration? {
        guard let raw else { return nil }
        guard let value = raw as? [String: Any],
              let provider = value["provider"] as? String,
              ["groq", "siliconflow", "openai-compatible", "local-command"].contains(provider),
              let language = value["language"] as? String,
              !language.isEmpty,
              language.count <= 12 else {
            throw error("invalid-asr-configuration")
        }
        let baseURL = value["baseURL"] as? String ?? ""
        let model = value["model"] as? String ?? ""
        let localCommand = value["localCommand"] as? String ?? ""
        if provider == "local-command" {
            guard !localCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw error("invalid-asr-configuration")
            }
        } else {
            guard !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw error("invalid-asr-configuration")
            }
        }
        return NativeManagedASRConfiguration(
            provider: provider,
            baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            model: model.trimmingCharacters(in: .whitespacesAndNewlines),
            language: language,
            localCommand: localCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private static func parseAgentProvider(_ raw: Any?) throws -> String? {
        guard let raw else { return nil }
        guard let value = raw as? String,
              ["codex", "claude", "auto"].contains(value) else {
            throw error("invalid-agent-provider")
        }
        return value
    }

    private static func parseProjectPresentation(
        _ raw: Any?
    ) throws -> NativeManagedProjectPresentation? {
        guard let raw else { return nil }
        guard let value = raw as? [String: Any],
              let projectName = value["projectName"] as? String,
              let showProjectName = boolean(value["showProjectName"]) else {
            throw error("invalid-project-presentation")
        }
        return NativeManagedProjectPresentation(
            projectName: projectName,
            showProjectName: showProjectName
        )
    }

    private static func parseSendMode(_ raw: Any?) throws -> NativeVoiceSendMode? {
        guard let raw else { return nil }
        guard let value = raw as? [String: Any],
              let sendMode = value["sendMode"] as? String,
              let normalized = NativeVoiceSendMode(rawValue: sendMode) else {
            throw error("invalid-voice-delivery")
        }
        return normalized
    }

    private static func optionalBoolean(_ object: [String: Any], key: String) throws -> Bool? {
        guard object.keys.contains(key) else { return nil }
        guard let result = boolean(object[key]) else {
            throw error("invalid-sound-preference")
        }
        return result
    }

    private static func integer(_ raw: Any?) -> Int? {
        guard let number = raw as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.rounded() == number.doubleValue else { return nil }
        return number.intValue
    }

    private static func boolean(_ raw: Any?) -> Bool? {
        guard let number = raw as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func error(_ code: String) -> NativeBridgeRuntimeConfigurationError {
        NativeBridgeRuntimeConfigurationError(code: code)
    }
}

protocol NativeManagedRuntimeFileReading {
    func read() throws -> Data?
}

struct NativeManagedRuntimeFileReader: NativeManagedRuntimeFileReading {
    static let maximumBytes = 1_048_576

    let path: URL
    var maximumBytes: Int = Self.maximumBytes

    func read() throws -> Data? {
        guard path.isFileURL, maximumBytes > 0 else {
            throw NativeBridgeRuntimeConfigurationError.unavailable()
        }
        let descriptor = path.path.withCString {
            Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw NativeBridgeRuntimeConfigurationError.unavailable()
        }
        defer { Darwin.close(descriptor) }

        var before = stat()
        guard fstat(descriptor, &before) == 0,
              (before.st_mode & S_IFMT) == S_IFREG,
              before.st_mode & 0o077 == 0,
              before.st_size > 0,
              before.st_size <= maximumBytes else {
            throw NativeBridgeRuntimeConfigurationError.unavailable()
        }

        var result = Data()
        result.reserveCapacity(Int(before.st_size))
        var remaining = Int(before.st_size)
        var buffer = [UInt8](repeating: 0, count: min(65_536, remaining))
        while remaining > 0 {
            let count = Darwin.read(descriptor, &buffer, min(buffer.count, remaining))
            if count < 0 {
                if errno == EINTR { continue }
                throw NativeBridgeRuntimeConfigurationError.unavailable()
            }
            if count == 0 { break }
            result.append(buffer, count: count)
            remaining -= count
        }
        var after = stat()
        guard remaining == 0,
              fstat(descriptor, &after) == 0,
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else {
            throw NativeBridgeRuntimeConfigurationError.unavailable()
        }
        return result
    }
}

enum NativeLegacyEnvironmentParser {
    static func parse(_ contents: String) -> [String: String] {
        var result: [String: String] = [:]
        for raw in contents.split(whereSeparator: \Character.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line.removeFirst("export ".count) }
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            if value.count >= 2,
               let first = value.first,
               first == value.last,
               first == "\"" || first == "'" {
                value.removeFirst()
                value.removeLast()
            }
            result[key] = value
        }
        return result
    }

    static func resolve(_ values: [String: String]) -> NativeResolvedRuntimeConfiguration {
        let token = NativeBridgeSecurity.normalizedBridgeToken(values["VIBE_STICK_BRIDGE_TOKEN"] ?? "")
        let provider = normalizedProvider(values["VIBE_STICK_ASR_PROVIDER"])
        let localCommand = cleaned(values["VIBE_STICK_TRANSCRIBE_CMD"])
        let asr: NativeManagedASRConfiguration?
        let apiKey: String
        if let localCommand {
            asr = NativeManagedASRConfiguration(
                provider: "local-command",
                baseURL: "",
                model: "",
                language: cleaned(values["VIBE_STICK_ASR_LANGUAGE"]) ?? "zh",
                localCommand: localCommand
            )
            apiKey = ""
        } else if provider != nil
                    || cleaned(values["VIBE_STICK_ASR_API_KEY"]) != nil
                    || cleaned(values["VIBE_STICK_GROQ_API_KEY"]) != nil {
            let selected = provider ?? (cleaned(values["VIBE_STICK_GROQ_API_KEY"]) != nil ? "groq" : "openai-compatible")
            let defaults = asrDefaults(selected)
            asr = NativeManagedASRConfiguration(
                provider: selected,
                baseURL: cleaned(values["VIBE_STICK_ASR_BASE_URL"]) ?? defaults.baseURL,
                model: cleaned(values["VIBE_STICK_ASR_MODEL"])
                    ?? cleaned(values["VIBE_STICK_GROQ_MODEL"])
                    ?? defaults.model,
                language: cleaned(values["VIBE_STICK_ASR_LANGUAGE"])
                    ?? cleaned(values["VIBE_STICK_GROQ_LANGUAGE"])
                    ?? "zh",
                localCommand: ""
            )
            apiKey = cleaned(values["VIBE_STICK_ASR_API_KEY"])
                ?? cleaned(values["VIBE_STICK_GROQ_API_KEY"])
                ?? ""
        } else {
            asr = nil
            apiKey = ""
        }
        let explicitSendMode = values["VIBE_STICK_SEND_MODE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
        let sendMode: NativeVoiceSendMode
        switch explicitSendMode {
        case "paste", "paste_only": sendMode = .pasteOnly
        case "confirm", "blue_button": sendMode = .confirm
        case "auto", "auto_send": sendMode = .autoSend
        default: sendMode = bool(values["VIBE_STICK_AUTO_ENTER"]) ? .autoSend : .pasteOnly
        }
        let agent = cleaned(values["VIBE_STICK_PROVIDER"])?.lowercased()
        let project = cleaned(values["VIBE_STICK_PROJECT_NAME"]).map {
            NativeManagedProjectPresentation(projectName: $0, showProjectName: true)
        }
        return NativeResolvedRuntimeConfiguration(
            mode: .legacy,
            bridgeToken: token,
            asrAPIKey: apiKey,
            asr: asr,
            agentProvider: ["codex", "claude", "auto"].contains(agent ?? "") ? agent! : "auto",
            projectPresentation: project,
            sendMode: sendMode,
            soundEnabled: nil
        )
    }

    private static func normalizedProvider(_ raw: String?) -> String? {
        switch cleaned(raw)?.lowercased() {
        case "groq": return "groq"
        case "siliconflow", "silicon-flow": return "siliconflow"
        case "openai", "openai-compatible": return "openai-compatible"
        case "command", "local-command": return "local-command"
        default: return nil
        }
    }

    private static func asrDefaults(_ provider: String) -> (baseURL: String, model: String) {
        switch provider {
        case "siliconflow": return ("https://api.siliconflow.cn/v1", "FunAudioLLM/SenseVoiceSmall")
        case "groq": return ("https://api.groq.com/openai/v1", "whisper-large-v3-turbo")
        default: return ("https://api.openai.com/v1", "gpt-4o-mini-transcribe")
        }
    }

    private static func cleaned(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func bool(_ raw: String?) -> Bool {
        ["1", "true", "yes", "on"].contains(raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "")
    }
}

enum NativeLegacyCompatibilityResolver {
    static func resolve(
        environment: String,
        appConfigurationData: Data?,
        asrCredentialReader: NativeManagedCredentialReading
    ) -> NativeResolvedRuntimeConfiguration {
        let base = NativeLegacyEnvironmentParser.resolve(
            NativeLegacyEnvironmentParser.parse(environment)
        )
        guard let appConfigurationData,
              appConfigurationData.count <= 65_536,
              let object = try? JSONSerialization.jsonObject(with: appConfigurationData) as? [String: Any],
              let asr = object["asr"] as? [String: Any],
              let provider = normalizedProvider(asr["provider"] as? String),
              let language = cleaned(asr["language"] as? String),
              language.count <= 12 else {
            return base
        }
        let configuration: NativeManagedASRConfiguration
        let key: String
        if provider == "local-command" {
            guard let command = cleaned(asr["localCommand"] as? String) else { return base }
            configuration = NativeManagedASRConfiguration(
                provider: provider,
                baseURL: "",
                model: "",
                language: language,
                localCommand: command
            )
            key = ""
        } else {
            guard let baseURL = cleaned(asr["baseURL"] as? String),
                  let model = cleaned(asr["model"] as? String) else { return base }
            configuration = NativeManagedASRConfiguration(
                provider: provider,
                baseURL: baseURL,
                model: model,
                language: language,
                localCommand: ""
            )
            key = (try? asrCredentialReader.read(
                service: NativeManagedRuntimeParser.keychainService,
                account: "asr-api-key"
            ))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        return NativeResolvedRuntimeConfiguration(
            mode: .legacy,
            bridgeToken: base.bridgeToken,
            asrAPIKey: key,
            asr: configuration,
            agentProvider: base.agentProvider,
            projectPresentation: base.projectPresentation,
            sendMode: base.sendMode,
            soundEnabled: base.soundEnabled
        )
    }

    private static func normalizedProvider(_ raw: String?) -> String? {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "groq": "groq"
        case "siliconflow", "silicon-flow": "siliconflow"
        case "openai", "openai-compatible": "openai-compatible"
        case "command", "local-command": "local-command"
        default: nil
        }
    }

    private static func cleaned(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}

struct NativeBridgeRuntimeConfigurationLoader {
    let fileReader: NativeManagedRuntimeFileReading
    let credentialReader: NativeManagedCredentialReading

    func load(
        expectedMode: NativeBridgeRuntimeMode?,
        legacyEnvironment: String
    ) throws -> NativeResolvedRuntimeConfiguration {
        let payload: Data?
        do {
            payload = try fileReader.read()
        } catch {
            throw NativeBridgeRuntimeConfigurationError.unavailable()
        }
        if expectedMode == .managed, payload == nil {
            throw NativeBridgeRuntimeConfigurationError.unavailable()
        }
        if expectedMode == .legacy, payload != nil {
            throw NativeBridgeRuntimeConfigurationError.unavailable("runtime-selection-changed")
        }
        if let payload {
            do {
                return try NativeManagedRuntimeParser.parse(payload, credentialReader: credentialReader)
            } catch {
                throw NativeBridgeRuntimeConfigurationError.unavailable()
            }
        }
        return NativeLegacyEnvironmentParser.resolve(
            NativeLegacyEnvironmentParser.parse(legacyEnvironment)
        )
    }
}
