import Foundation
import Testing

struct VibeStickAppTests {
    @Test
    func decodesCurrentBridgePayload() throws {
        let data = Data(
            """
            {
              "time": "12:34",
              "wifi": true,
              "battery": null,
              "active_provider": "codex",
              "provider": {
                "id": "codex",
                "display_name": "Codex",
                "status": "RUNNING",
                "project": "M5StickS3",
                "quota_5h_remaining": null,
                "quota_7d_remaining": 90,
                "quota_updated_at": null,
                "quota_stale": false
              },
              "bridge_name": "vibestick-bridge",
              "bridge_version": "0.1.4"
            }
            """.utf8
        )

        let state = try JSONDecoder().decode(BridgeStateDTO.self, from: data)
        #expect(state.activeProvider == "codex")
        #expect(state.provider.quota5HRemaining == nil)
        #expect(state.provider.quota7DRemaining == 90)
    }

    @Test
    func keepsCodexCardIndependentFromActiveProvider() throws {
        let data = Data(
            """
            {
              "time": "12:34",
              "wifi": true,
              "battery": null,
              "active_provider": "claude",
              "provider": {
                "id": "claude",
                "display_name": "Claude",
                "status": "RUNNING",
                "project": "Other",
                "quota_5h_remaining": null,
                "quota_7d_remaining": 12,
                "quota_updated_at": null,
                "quota_stale": false
              },
              "codex": {
                "id": "codex",
                "display_name": "Codex",
                "status": "IDLE",
                "project": "VibeStick",
                "quota_5h_remaining": null,
                "quota_7d_remaining": 88,
                "quota_updated_at": null,
                "quota_stale": true
              }
            }
            """.utf8
        )

        let state = try JSONDecoder().decode(BridgeStateDTO.self, from: data)
        #expect(state.codexState?.id == "codex")
        #expect(state.codexState?.quota7DRemaining == 88)
        #expect(state.codexState?.quotaStale == true)
    }

    @Test
    func persistedPreferencesContainNoSecretFields() throws {
        let data = try JSONEncoder().encode(AppConfiguration.standard)
        let json = String(decoding: data, as: UTF8.self).lowercased()
        #expect(!json.contains("token"))
        #expect(!json.contains("api_key"))
        #expect(!json.contains("password"))
    }

    @Test
    func parsesExistingEnvironmentWithoutExposingComments() {
        let values = LegacyEnvironmentParser.parse(
            """
            # comment
            export VIBE_STICK_ASR_PROVIDER="groq"
            VIBE_STICK_AUTO_ENTER=1
            VIBE_STICK_PROJECT_NAME='M5StickS3'
            """
        )
        #expect(values["VIBE_STICK_ASR_PROVIDER"] == "groq")
        #expect(values["VIBE_STICK_AUTO_ENTER"] == "1")
        #expect(values["VIBE_STICK_PROJECT_NAME"] == "M5StickS3")
        #expect(values.count == 3)
    }

    @Test
    func runningBridgeIsNotAutomaticallyReady() {
        let component = ServiceStateResolver.launchAgent(
            kind: .bridge,
            installed: true,
            loaded: true,
            running: true,
            ready: false
        )
        #expect(component.phase == .runningNotReady)
    }

    @Test
    func parsesLaunchAgentRunningState() {
        let output = "state = running\nprogram = /Applications/VibeStickBridge\npid = 42"
        #expect(LaunchAgentStateParser.isRunning(output))
        #expect(LaunchAgentStateParser.programPath(output) == "/Applications/VibeStickBridge")
        #expect(!LaunchAgentStateParser.isRunning("state = waiting\nlast exit code = 1"))
    }

    @Test
    func protectsFreshRecordingWhenHealthEndpointIsUnavailable() {
        let now = Date(timeIntervalSince1970: 1_000)
        let protected = RecordingActivityResolver.shouldProtect(
            claimsActive: true,
            modifiedAt: now.addingTimeInterval(-30),
            bridgeProcessRunning: true,
            now: now
        )
        #expect(protected)
    }

    @Test
    func releasesStaleOrOrphanedRecordingClaim() {
        let now = Date(timeIntervalSince1970: 1_000)
        #expect(!RecordingActivityResolver.shouldProtect(
            claimsActive: true,
            modifiedAt: now.addingTimeInterval(-601),
            bridgeProcessRunning: true,
            now: now
        ))
        #expect(!RecordingActivityResolver.shouldProtect(
            claimsActive: true,
            modifiedAt: now.addingTimeInterval(-30),
            bridgeProcessRunning: false,
            now: now
        ))
    }

    @Test
    func pastePermissionProbeLaunchesTheBundleThroughLaunchServices() throws {
        let command = PastePermissionProbeProtocol.launchCommand(
            appPath: "/Library/Application Support/VibeStick/VibeStick Paste.app",
            requestPath: "/tmp/request.json",
            responsePath: "/tmp/response.json"
        )

        #expect(command.executable == "/usr/bin/open")
        #expect(command.arguments == [
            "-g",
            "-n",
            "/Library/Application Support/VibeStick/VibeStick Paste.app",
            "--args",
            "--request",
            "/tmp/request.json",
            "--response",
            "/tmp/response.json",
        ])
        #expect(!command.arguments.contains("-W"))
        #expect(!command.arguments.contains("VibeStickPaste"))

        let allowed = Data(#"{"success":true,"message":"enabled"}"#.utf8)
        let denied = Data(#"{"success":false,"message":"disabled"}"#.utf8)
        #expect(PastePermissionProbeProtocol.permission(from: allowed) == true)
        #expect(PastePermissionProbeProtocol.permission(from: denied) == false)
        #expect(PastePermissionProbeProtocol.permission(from: Data("not json".utf8)) == nil)
    }

    @Test
    func loadedButInactiveServiceNeedsRepair() {
        let component = ServiceStateResolver.launchAgent(
            kind: .hud,
            installed: true,
            loaded: true,
            running: false,
            ready: nil
        )
        #expect(component.phase == .needsRepair)
    }

    @Test
    func unknownHealthResponderIsTreatedAsPortConflict() {
        let snapshot = BridgeSnapshot(
            health: nil,
            state: nil,
            healthEndpointResponded: true,
            errorMessage: "invalid payload",
            checkedAt: Date()
        )
        #expect(snapshot.hasPortConflict)
        #expect(!snapshot.isHealthy)
    }

    @Test
    func stoppedServiceRemainsInstalled() {
        let component = ServiceStateResolver.launchAgent(
            kind: .hud,
            installed: true,
            loaded: false,
            running: false,
            ready: nil
        )
        #expect(component.phase == .stopped)
        #expect(component.isInstalled)
    }

    @Test
    func preferencesPersistAtomicallyWithPrivatePermissions() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VibeStickPreferencesTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("config-v1.json")
        let store = PreferencesStore(fileURL: file)
        var expected = AppConfiguration.standard
        expected.showTechnicalDetails = true
        expected.refreshIntervalSeconds = 30

        try await store.save(expected)
        let loaded = await store.load()
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue

        #expect(loaded == expected)
        #expect(permissions == 0o600)
    }

    @Test
    func legacyInspectionReturnsOnlyRedactedSummary() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VibeStickInspectionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent(".env")
        try Data(
            """
            VIBE_STICK_ASR_PROVIDER=groq
            VIBE_STICK_ASR_API_KEY=placeholder-not-a-real-key
            VIBE_STICK_AUTO_ENTER=0
            """.utf8
        ).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        let inspector = ConfigurationInspector(
            environmentFile: file,
            keychainStore: MockSecretStore(present: [.bridgeToken])
        )

        let result = await inspector.inspect()
        #expect(result.legacy.asrConfigurationDetected)
        #expect(result.legacy.asrProvider == "groq")
        #expect(result.legacy.containsLegacySecrets)
        #expect(result.legacy.legacyFileIsOverexposed)
        #expect(result.keychain.bridgeTokenStored)
        #expect(!result.keychain.asrKeyStored)
    }
}

private struct MockSecretStore: SecretStoring {
    let present: Set<KeychainSecret>

    func contains(_ key: KeychainSecret) -> Bool {
        present.contains(key)
    }
}
