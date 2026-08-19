import Foundation
import Testing

@Suite("Native Swift Bridge production assembly boundary")
struct NativeBridgeProductionFactoryTests {
    @Test("managed startup is selected without reading legacy inputs")
    func managedSelection() throws {
        var legacyEnvironmentReads = 0
        var legacyConfigurationReads = 0
        func legacyEnvironment() -> String {
            legacyEnvironmentReads += 1
            return "VIBE_STICK_BRIDGE_TOKEN=must-not-be-used"
        }
        func legacyConfiguration() -> Data? {
            legacyConfigurationReads += 1
            return Data("not-json".utf8)
        }
        let credentials = ProductionFactoryCredentialReader(values: [
            "bridge-token-v1": "fixture-managed-token",
        ])
        let legacy = ProductionFactoryCredentialReader(values: [
            "asr-api-key": "must-not-be-read",
        ])
        let configuration = try NativeBridgeProductionFactory.loadConfiguration(
            expectedMode: .managed,
            managedFileReader: ProductionFactoryFileReader(payload: managedData()),
            managedCredentialReader: credentials,
            legacyEnvironment: legacyEnvironment(),
            legacyAppConfiguration: legacyConfiguration(),
            legacyASRCredentialReader: legacy
        )
        #expect(configuration.mode == .managed)
        #expect(configuration.bridgeToken == "fixture-managed-token")
        #expect(credentials.accounts == ["bridge-token-v1"])
        #expect(legacy.accounts.isEmpty)
        #expect(legacyEnvironmentReads == 0)
        #expect(legacyConfigurationReads == 0)
    }

    @Test("invalid managed document never falls back to a valid legacy token")
    func managedFailureNoFallback() {
        let credentials = ProductionFactoryCredentialReader(values: [:])
        #expect(throws: NativeBridgeRuntimeConfigurationError.self) {
            try NativeBridgeProductionFactory.loadConfiguration(
                expectedMode: nil,
                managedFileReader: ProductionFactoryFileReader(payload: Data("{}".utf8)),
                managedCredentialReader: credentials,
                legacyEnvironment: "VIBE_STICK_BRIDGE_TOKEN=fixture-legacy-token",
                legacyAppConfiguration: nil,
                legacyASRCredentialReader: credentials
            )
        }
    }

    @Test("managed startup preserves only the fixed redacted failure category")
    func managedFailureCategoryIsRedactedAndStable() {
        let credentials = ProductionFactoryCredentialReader(values: [:])
        do {
            _ = try NativeBridgeProductionFactory.loadConfiguration(
                expectedMode: nil,
                managedFileReader: ProductionFactoryFileReader(payload: Data("{}".utf8)),
                managedCredentialReader: credentials,
                legacyEnvironment: "VIBE_STICK_BRIDGE_TOKEN=must-not-be-used",
                legacyAppConfiguration: nil,
                legacyASRCredentialReader: credentials
            )
            Issue.record("expected managed configuration failure")
        } catch let error as NativeBridgeRuntimeConfigurationError {
            #expect(error.code == "unsupported-managed-configuration")
        } catch {
            Issue.record("unexpected failure type")
        }
    }

    @Test("legacy startup remains available only when managed document is absent")
    func legacySelection() throws {
        let credentials = ProductionFactoryCredentialReader(values: [:])
        let result = try NativeBridgeProductionFactory.loadConfiguration(
            expectedMode: .legacy,
            managedFileReader: ProductionFactoryFileReader(payload: nil),
            managedCredentialReader: credentials,
            legacyEnvironment: "VIBE_STICK_BRIDGE_TOKEN=fixture-legacy-token",
            legacyAppConfiguration: nil,
            legacyASRCredentialReader: credentials
        )
        #expect(result.mode == .legacy)
        #expect(result.bridgeToken == "fixture-legacy-token")
    }

    @Test("recording request limit is fixed and bounded")
    func recordingLimit() {
        #expect(NativeBridgeProductionFactory.normalizedAudioLimit(nil) == 2_000_000)
        #expect(NativeBridgeProductionFactory.normalizedAudioLimit("bad") == 2_000_000)
        #expect(NativeBridgeProductionFactory.normalizedAudioLimit("1") == 256_000)
        #expect(NativeBridgeProductionFactory.normalizedAudioLimit("99999999") == 8_000_000)
    }

    @Test("voice transcription reloads its adapter for every recording")
    func voiceTranscriberReloadsPerRecording() {
        var revision = 0
        let transcriber = NativeReloadingVoiceTranscriber {
            revision += 1
            return ProductionFactoryTranscriberFixture(revision: revision)
        }
        let session = NativeVoiceRecordingSession(sessionID: "fixture-session")

        let first = transcriber.transcribe(session: session, explicitText: "")
        let second = transcriber.transcribe(session: session, explicitText: "")

        #expect(first.text == "fixture-revision-1")
        #expect(second.text == "fixture-revision-2")
    }

    @Test("Bridge entry point contains no Python bootstrap")
    func nativeEntryPoint() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("VibeStickBridge/main.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        #expect(text.contains("NativeBridgeProductionFactory.make"))
        #expect(text.contains("NativeBridgeRuntimeConfigurationError"))
        #expect(text.contains("error.code"))
        #expect(!text.lowercased().contains("python"))
        #expect(!text.contains("execv"))
        #expect(!text.contains("PYTHONPATH"))
    }

    private func managedData() -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "credentialReferences": [[
                "schemaVersion": 1,
                "purpose": "bridge-token",
                "storage": "macos-keychain",
                "service": "io.github.hanminyin.vibestick",
                "account": "bridge-token-v1",
            ]],
            "agentProvider": "auto",
            "voiceDelivery": ["sendMode": "paste_only"],
        ], options: [.sortedKeys])
    }
}

private struct ProductionFactoryFileReader: NativeManagedRuntimeFileReading {
    let payload: Data?
    func read() throws -> Data? { payload }
}

private final class ProductionFactoryCredentialReader: NativeManagedCredentialReading {
    let values: [String: String]
    private(set) var accounts: [String] = []

    init(values: [String: String]) { self.values = values }

    func read(service: String, account: String) throws -> String {
        accounts.append(account)
        guard let value = values[account] else {
            throw NativeBridgeRuntimeConfigurationError.unavailable("fixture-missing")
        }
        return value
    }
}

private final class ProductionFactoryTranscriberFixture: NativeVoiceTranscriber {
    let revision: Int

    init(revision: Int) {
        self.revision = revision
    }

    func transcribe(
        session: NativeVoiceRecordingSession,
        explicitText: String
    ) -> NativeVoiceTranscriptionResult {
        NativeVoiceTranscriptionResult(
            text: "fixture-revision-\(revision)",
            success: true,
            message: "fixture",
            source: "fixture"
        )
    }
}
