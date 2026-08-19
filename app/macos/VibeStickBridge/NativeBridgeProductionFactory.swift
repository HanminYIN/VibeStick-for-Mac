import Foundation

struct NativeBridgeProductionAssembly {
    let configuration: NativeResolvedRuntimeConfiguration
    let store: NativeBridgeRuntimeStore
    let server: NativeBridgeHTTPServer
}

final class NativeReloadingVoiceTranscriber: NativeVoiceTranscriber {
    private let makeTranscriber: () throws -> any NativeVoiceTranscriber

    init(makeTranscriber: @escaping () throws -> any NativeVoiceTranscriber) {
        self.makeTranscriber = makeTranscriber
    }

    func transcribe(
        session: NativeVoiceRecordingSession,
        explicitText: String
    ) -> NativeVoiceTranscriptionResult {
        do {
            return try makeTranscriber().transcribe(
                session: session,
                explicitText: explicitText
            )
        } catch {
            return NativeVoiceTranscriptionResult(
                text: "",
                success: false,
                message: "ASR configuration is unavailable",
                source: "configuration"
            )
        }
    }
}

enum NativeBridgeProductionFactory {
    static let host = "0.0.0.0"
    static let port: UInt16 = 8_765

    static func loadConfiguration(
        expectedMode: NativeBridgeRuntimeMode?,
        managedFileReader: NativeManagedRuntimeFileReading,
        managedCredentialReader: NativeManagedCredentialReading,
        legacyEnvironment: @autoclosure () -> String,
        legacyAppConfiguration: @autoclosure () -> Data?,
        legacyASRCredentialReader: NativeManagedCredentialReading
    ) throws -> NativeResolvedRuntimeConfiguration {
        let payload: Data?
        do {
            payload = try managedFileReader.read()
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
                return try NativeManagedRuntimeParser.parse(
                    payload,
                    credentialReader: managedCredentialReader
                )
            } catch let error as NativeBridgeRuntimeConfigurationError {
                throw error
            } catch {
                throw NativeBridgeRuntimeConfigurationError.unavailable()
            }
        }
        return NativeLegacyCompatibilityResolver.resolve(
            environment: legacyEnvironment(),
            appConfigurationData: legacyAppConfiguration(),
            asrCredentialReader: legacyASRCredentialReader
        )
    }

    static func make(
        supportDirectory: URL,
        homeDirectory: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> NativeBridgeProductionAssembly {
        guard supportDirectory.isFileURL, homeDirectory.isFileURL else {
            throw NativeBridgeRuntimeConfigurationError.unavailable("invalid-runtime-path")
        }
        try FileManager.default.createDirectory(
            at: supportDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: supportDirectory.path
        )
        let paths = NativeBridgeRuntimePaths(
            supportDirectory: supportDirectory,
            homeDirectory: homeDirectory
        )
        let expectedMode: NativeBridgeRuntimeMode?
        let rawMode = environment["VIBE_STICK_RUNTIME_SELECTION"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        if rawMode.isEmpty {
            expectedMode = nil
        } else if let mode = NativeBridgeRuntimeMode(rawValue: rawMode) {
            expectedMode = mode
        } else {
            throw NativeBridgeRuntimeConfigurationError.unavailable("runtime-selection-unavailable")
        }
        let configuration = try loadConfiguration(
            expectedMode: expectedMode,
            managedFileReader: NativeManagedRuntimeFileReader(
                path: supportDirectory.appendingPathComponent("managed-runtime-v1.json")
            ),
            managedCredentialReader: NativeManagedKeychainCredentialReader(),
            legacyEnvironment: readText(
                supportDirectory.appendingPathComponent(".env"),
                maximumBytes: 1_048_576
            ),
            legacyAppConfiguration: try? NativeBridgeSecureFile.readData(
                at: supportDirectory.appendingPathComponent("config-v1.json"),
                maximumBytes: 65_536
            ),
            legacyASRCredentialReader: NativeLegacyASRKeychainReader()
        )

        let audioStore = NativeVoiceFileAudioStore(recordingsDirectory: paths.recordings)
        let selectedMode = configuration.mode
        let transcriber = NativeReloadingVoiceTranscriber {
            let latest = try loadConfiguration(
                expectedMode: selectedMode,
                managedFileReader: NativeManagedRuntimeFileReader(
                    path: supportDirectory.appendingPathComponent("managed-runtime-v1.json")
                ),
                managedCredentialReader: NativeManagedKeychainCredentialReader(),
                legacyEnvironment: readText(
                    supportDirectory.appendingPathComponent(".env"),
                    maximumBytes: 1_048_576
                ),
                legacyAppConfiguration: try? NativeBridgeSecureFile.readData(
                    at: supportDirectory.appendingPathComponent("config-v1.json"),
                    maximumBytes: 65_536
                ),
                legacyASRCredentialReader: NativeLegacyASRKeychainReader()
            )
            return makeVoiceTranscriber(configuration: latest)
        }
        let voice = NativeVoiceRecordingController(
            path: paths.recording,
            pendingSend: NativePendingSendCoordinator(path: paths.pendingSend),
            recorder: NativeAVFoundationRecorder(recordingsDirectory: paths.recordings),
            transcriber: transcriber,
            pasteClient: NativePasteHelperClient(helperApp: paths.pasteHelper),
            audioStore: audioStore,
            hud: NativeHUDStateClient(path: paths.hudState),
            managedSendMode: configuration.mode == .managed ? configuration.sendMode : nil
        )
        let registry = NativePairedDeviceRegistry(path: paths.registry)
        let deviceConfiguration = NativeDeviceConfigurationStore(
            path: paths.deviceConfiguration,
            managedProjectPresentation: configuration.mode == .managed
                ? configuration.projectPresentation?.jsonObject : nil
        )
        let fallbackProject = configuration.projectPresentation?.projectName
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let observer = NativeProviderRuntimeObserver(
            homeDirectory: homeDirectory,
            fallbackProject: fallbackProject?.isEmpty == false ? fallbackProject! : "vibestick"
        )
        let quotaClient = NativeCodexQuotaClient()
        let claudeSettings = NativeClaudeUsageSettings(environment: environment)
        let claudeCredentials = NativeClaudeCredentialResolver(
            environment: environment,
            homeDirectory: homeDirectory
        )
        let claudeUsageClient = NativeClaudeUsageClient(resolveToken: claudeCredentials.token)
        let store = NativeBridgeRuntimeStore(
            bridgeID: try NativeBridgeIdentityStore(path: paths.identity).bridgeID(),
            bridgeToken: configuration.bridgeToken,
            configuredProvider: configuration.agentProvider,
            registry: registry,
            deviceConfiguration: deviceConfiguration,
            stateDocument: NativeBridgeStateDocument(path: paths.state),
            quotaStore: NativeQuotaStore(path: paths.codexQuota),
            claudeQuotaStore: NativeQuotaStore(path: paths.claudeQuota),
            voice: voice,
            observeProviders: observer.observations,
            fetchAccountQuota: quotaClient.fetch,
            fetchClaudeQuota: claudeUsageClient.fetch,
            claudeUsageEnabled: claudeSettings.enabled,
            claudeUsageInterval: claudeSettings.interval
        )
        let maximumAudioBytes = normalizedAudioLimit(environment["VIBE_STICK_MAX_RECORDING_AUDIO_BYTES"])
        let router = NativeBridgeRouter(store: store, maxRecordingAudioBytes: maximumAudioBytes)
        let server = try NativeBridgeHTTPServer(
            host: host,
            port: port,
            bridgeID: store.bridgeID,
            bridgeToken: store.bridgeToken,
            pairedDeviceCount: registry.devices().filter { !$0.revoked }.count,
            router: router,
            maximumBodyBytes: maximumAudioBytes
        )
        return NativeBridgeProductionAssembly(
            configuration: configuration,
            store: store,
            server: server
        )
    }

    static func normalizedAudioLimit(_ raw: String?) -> Int {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              let value = Int(raw) else { return 2_000_000 }
        return min(8_000_000, max(256_000, value))
    }

    private static func makeVoiceTranscriber(
        configuration: NativeResolvedRuntimeConfiguration
    ) -> any NativeVoiceTranscriber {
        if let command = configuration.localTranscriptionCommand {
            return NativeLocalCommandTranscriber(command: command)
        }
        return NativeOpenAICompatibleTranscriber(
            configuration: configuration.cloudASRConfiguration
        )
    }

    private static func readText(_ path: URL, maximumBytes: Int) -> String {
        guard let data = try? NativeBridgeSecureFile.readData(
            at: path,
            maximumBytes: maximumBytes
        ) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
