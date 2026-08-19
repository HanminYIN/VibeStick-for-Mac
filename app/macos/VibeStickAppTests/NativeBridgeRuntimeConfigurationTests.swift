import Foundation
import Testing

@Suite("Native Swift Bridge runtime configuration")
struct NativeBridgeRuntimeConfigurationTests {
    @Test("managed configuration resolves only fixed versioned credentials")
    func managedConfiguration() throws {
        let reader = FictionalManagedCredentialReader(values: [
            "bridge-token-v1": "fixture-bridge-token-that-is-not-real",
            "asr-api-key-v1": "fixture-asr-key-that-is-not-real",
        ])
        let result = try NativeManagedRuntimeParser.parse(
            managedFixture(),
            credentialReader: reader
        )

        #expect(result.mode == .managed)
        #expect(result.bridgeToken == "fixture-bridge-token-that-is-not-real")
        #expect(result.agentProvider == "codex")
        #expect(result.sendMode == .confirm)
        #expect(result.projectPresentation?.projectName == "Fictional Project")
        #expect(result.cloudASRConfiguration?.provider == "groq")
        #expect(reader.requested == [
            "io.github.hanminyin.vibestick/bridge-token-v1",
            "io.github.hanminyin.vibestick/asr-api-key-v1",
        ])
    }

    @Test("unknown arbitrary and duplicate credential references fail closed")
    func invalidReferences() {
        let reader = FictionalManagedCredentialReader(values: [:])
        var arbitrary = managedObject()
        arbitrary["credentialReferences"] = [[
            "schemaVersion": 1,
            "purpose": "bridge-token",
            "storage": "macos-keychain",
            "service": "io.github.hanminyin.vibestick",
            "account": "arbitrary-account",
        ]]
        #expect(throws: NativeBridgeRuntimeConfigurationError.self) {
            try NativeManagedRuntimeParser.parse(data(arbitrary), credentialReader: reader)
        }

        var duplicate = managedObject()
        let references = duplicate["credentialReferences"] as? [[String: Any]] ?? []
        duplicate["credentialReferences"] = references + [references[0]]
        #expect(throws: NativeBridgeRuntimeConfigurationError.self) {
            try NativeManagedRuntimeParser.parse(data(duplicate), credentialReader: reader)
        }
    }

    @Test("placeholder token and missing cloud key fail without exposing values")
    func missingCredentials() {
        let placeholder = FictionalManagedCredentialReader(values: [
            "bridge-token-v1": "change-this-shared-token",
            "asr-api-key-v1": "fixture-asr-key",
        ])
        #expect(throws: NativeBridgeRuntimeConfigurationError.self) {
            try NativeManagedRuntimeParser.parse(managedFixture(), credentialReader: placeholder)
        }

        let missing = FictionalManagedCredentialReader(values: [
            "bridge-token-v1": "fixture-bridge-token",
        ])
        do {
            _ = try NativeManagedRuntimeParser.parse(managedFixture(), credentialReader: missing)
            Issue.record("expected managed parser to fail")
        } catch {
            let description = String(describing: error)
            #expect(description == "missing-asr-credential")
            #expect(!description.contains("fixture-bridge-token"))
        }
    }

    @Test("local command never asks for ASR credential")
    func localCommand() throws {
        var object = managedObject()
        object["credentialReferences"] = [credentialReference("bridge-token", "bridge-token-v1")]
        object["asr"] = [
            "provider": "local-command",
            "baseURL": "",
            "model": "",
            "language": "zh",
            "localCommand": "/usr/local/bin/fictional-transcriber",
        ]
        let reader = FictionalManagedCredentialReader(values: [
            "bridge-token-v1": "fixture-bridge-token",
        ])
        let result = try NativeManagedRuntimeParser.parse(data(object), credentialReader: reader)
        #expect(result.localTranscriptionCommand == "/usr/local/bin/fictional-transcriber")
        #expect(result.asrAPIKey.isEmpty)
        #expect(reader.requested == ["io.github.hanminyin.vibestick/bridge-token-v1"])
    }

    @Test("managed optional values are type checked")
    func managedTypes() {
        let reader = FictionalManagedCredentialReader(values: [
            "bridge-token-v1": "fixture-bridge-token",
            "asr-api-key-v1": "fixture-asr-key",
        ])
        for mutation in [
            ("agentProvider", 12),
            ("projectPresentation", ["projectName": "x", "showProjectName": "yes"]),
            ("voiceDelivery", ["sendMode": "unsafe"]),
            ("soundEnabled", "yes"),
        ] as [(String, Any)] {
            var object = managedObject()
            object[mutation.0] = mutation.1
            #expect(throws: NativeBridgeRuntimeConfigurationError.self) {
                try NativeManagedRuntimeParser.parse(data(object), credentialReader: reader)
            }
        }
    }

    @Test("managed runtime file must be private regular bounded and not a symlink")
    func secureManagedFile() throws {
        try withRuntimeTemporaryDirectory { directory in
            let real = directory.appendingPathComponent("managed-runtime-v1.json")
            try managedFixture().write(to: real)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: real.path)
            #expect(try NativeManagedRuntimeFileReader(path: real).read() == managedFixture())

            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: real.path)
            #expect(throws: NativeBridgeRuntimeConfigurationError.self) {
                try NativeManagedRuntimeFileReader(path: real).read()
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: real.path)

            let link = directory.appendingPathComponent("managed-link.json")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
            #expect(throws: NativeBridgeRuntimeConfigurationError.self) {
                try NativeManagedRuntimeFileReader(path: link).read()
            }
            #expect(throws: NativeBridgeRuntimeConfigurationError.self) {
                try NativeManagedRuntimeFileReader(path: real, maximumBytes: 10).read()
            }
        }
    }

    @Test("startup mode never falls back across a managed selection")
    func startupSelection() throws {
        let credentials = FictionalManagedCredentialReader(values: [
            "bridge-token-v1": "fixture-bridge-token",
            "asr-api-key-v1": "fixture-asr-key",
        ])
        let managed = NativeBridgeRuntimeConfigurationLoader(
            fileReader: FictionalManagedFileReader(payload: managedFixture()),
            credentialReader: credentials
        )
        #expect(throws: NativeBridgeRuntimeConfigurationError.self) {
            try managed.load(expectedMode: .legacy, legacyEnvironment: "VIBE_STICK_BRIDGE_TOKEN=legacy")
        }

        let absent = NativeBridgeRuntimeConfigurationLoader(
            fileReader: FictionalManagedFileReader(payload: nil),
            credentialReader: credentials
        )
        #expect(throws: NativeBridgeRuntimeConfigurationError.self) {
            try absent.load(expectedMode: .managed, legacyEnvironment: "VIBE_STICK_BRIDGE_TOKEN=legacy")
        }
        let legacy = try absent.load(
            expectedMode: .legacy,
            legacyEnvironment: "VIBE_STICK_BRIDGE_TOKEN=fixture-legacy-token"
        )
        #expect(legacy.mode == .legacy)
        #expect(legacy.bridgeToken == "fixture-legacy-token")
    }

    @Test("legacy parser preserves quoted values providers and safe send defaults")
    func legacyCompatibility() {
        let values = NativeLegacyEnvironmentParser.parse("""
        # ignored
        export VIBE_STICK_BRIDGE_TOKEN='fixture legacy token'
        VIBE_STICK_ASR_PROVIDER= silicon-flow
        VIBE_STICK_ASR_API_KEY="fixture-asr-key"
        VIBE_STICK_SEND_MODE=blue-button
        VIBE_STICK_PROJECT_NAME=Fictional Project
        """)
        let result = NativeLegacyEnvironmentParser.resolve(values)
        #expect(result.bridgeToken == "fixture legacy token")
        #expect(result.asr?.provider == "siliconflow")
        #expect(result.asr?.baseURL == "https://api.siliconflow.cn/v1")
        #expect(result.sendMode == .confirm)
        #expect(result.projectPresentation?.projectName == "Fictional Project")
    }

    @Test("legacy App ASR configuration outranks environment and uses only old fixed key")
    func legacyAppASRPrecedence() throws {
        let credentials = FictionalManagedCredentialReader(values: [
            "asr-api-key": "fixture-legacy-key",
        ])
        let app = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "asr": [
                "provider": "groq",
                "baseURL": "https://api.groq.com/openai/v1",
                "model": "app-model",
                "language": "zh",
                "localCommand": "",
            ],
        ])
        let result = NativeLegacyCompatibilityResolver.resolve(
            environment: """
            VIBE_STICK_BRIDGE_TOKEN=fixture-token
            VIBE_STICK_ASR_PROVIDER=siliconflow
            VIBE_STICK_ASR_API_KEY=environment-key
            """,
            appConfigurationData: app,
            asrCredentialReader: credentials
        )
        #expect(result.asr?.provider == "groq")
        #expect(result.asr?.model == "app-model")
        #expect(result.asrAPIKey == "fixture-legacy-key")
        #expect(credentials.requested == ["io.github.hanminyin.vibestick/asr-api-key"])
    }

    @Test("legacy App local command never reads a key")
    func legacyAppLocalCommand() throws {
        let credentials = FictionalManagedCredentialReader(values: [:])
        let app = try JSONSerialization.data(withJSONObject: [
            "asr": [
                "provider": "local-command",
                "baseURL": "",
                "model": "",
                "language": "zh",
                "localCommand": "/fictional/local-asr",
            ],
        ])
        let result = NativeLegacyCompatibilityResolver.resolve(
            environment: "VIBE_STICK_BRIDGE_TOKEN=fixture-token",
            appConfigurationData: app,
            asrCredentialReader: credentials
        )
        #expect(result.localTranscriptionCommand == "/fictional/local-asr")
        #expect(credentials.requested.isEmpty)
    }

    @Test("managed Keychain reader falls back to the fixed trusted security tool without prompting")
    func managedKeychainTrustedToolFallback() throws {
        let recorder = NativeSecurityInvocationRecorder()
        let reader = NativeManagedKeychainCredentialReader(
            runSecurity: { arguments in
                recorder.record(arguments)
                return NativeSecurityCommandResult(
                    status: 0,
                    standardOutput: Data("fixture-bridge-token\n".utf8)
                )
            }
        )

        let value = try reader.read(
            service: "io.github.hanminyin.vibestick",
            account: "bridge-token-v1"
        )

        #expect(value == "fixture-bridge-token")
        #expect(recorder.arguments == [[
            "find-generic-password",
            "-s", "io.github.hanminyin.vibestick",
            "-a", "bridge-token-v1",
            "-w",
        ]])
    }

    @Test("Keychain reader rejects untrusted references and redacts command failures")
    func managedKeychainFailureIsFixedAndRedacted() {
        let recorder = NativeSecurityInvocationRecorder()
        let reader = NativeManagedKeychainCredentialReader(
            runSecurity: { arguments in
                recorder.record(arguments)
                return NativeSecurityCommandResult(
                    status: 44,
                    standardOutput: Data("fixture-secret-must-not-escape".utf8)
                )
            }
        )

        #expect(throws: NativeBridgeRuntimeConfigurationError.self) {
            try reader.read(
                service: "io.github.hanminyin.vibestick",
                account: "arbitrary-account"
            )
        }
        #expect(recorder.arguments.isEmpty)

        do {
            _ = try reader.read(
                service: "io.github.hanminyin.vibestick",
                account: "asr-api-key-v1"
            )
            Issue.record("expected fixed Keychain failure")
        } catch {
            let description = String(describing: error)
            #expect(description == "managed-credential-unavailable")
            #expect(!description.contains("fixture-secret-must-not-escape"))
        }
    }

    private func managedFixture() -> Data { data(managedObject()) }

    private func managedObject() -> [String: Any] {
        [
            "schemaVersion": 1,
            "credentialReferences": [
                credentialReference("bridge-token", "bridge-token-v1"),
                credentialReference("asr-api-key", "asr-api-key-v1"),
            ],
            "asr": [
                "provider": "groq",
                "baseURL": "https://api.groq.com/openai/v1",
                "model": "whisper-large-v3-turbo",
                "language": "zh",
                "localCommand": "",
            ],
            "agentProvider": "codex",
            "projectPresentation": [
                "projectName": "Fictional Project",
                "showProjectName": true,
            ],
            "voiceDelivery": ["sendMode": "confirm"],
            "soundEnabled": true,
        ]
    }

    private func credentialReference(_ purpose: String, _ account: String) -> [String: Any] {
        [
            "schemaVersion": 1,
            "purpose": purpose,
            "storage": "macos-keychain",
            "service": "io.github.hanminyin.vibestick",
            "account": account,
        ]
    }

    private func data(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

private final class FictionalManagedCredentialReader: NativeManagedCredentialReading {
    let values: [String: String]
    private(set) var requested: [String] = []

    init(values: [String: String]) { self.values = values }

    func read(service: String, account: String) throws -> String {
        requested.append("\(service)/\(account)")
        guard let value = values[account] else {
            throw NativeBridgeRuntimeConfigurationError.unavailable("fictional-missing")
        }
        return value
    }
}

private struct FictionalManagedFileReader: NativeManagedRuntimeFileReading {
    let payload: Data?
    func read() throws -> Data? { payload }
}

private final class NativeSecurityInvocationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedArguments: [[String]] = []

    var arguments: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return storedArguments
    }

    func record(_ arguments: [String]) {
        lock.lock()
        storedArguments.append(arguments)
        lock.unlock()
    }
}

private func withRuntimeTemporaryDirectory(_ operation: (URL) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("VibeStick-NativeRuntime-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    try operation(directory)
}
