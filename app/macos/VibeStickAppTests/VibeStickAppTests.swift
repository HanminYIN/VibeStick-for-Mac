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
    func decodesM3BVoiceCapabilityFromBridgeHealth() throws {
        let data = Data(
            """
            {
              "ok": true,
              "bridge_name": "vibestick-bridge",
              "bridge_version": "0.2.0-dev",
              "protocol_version": 2,
              "voice_interaction_version": 2,
              "bridge_id": "90d71007-7734-44f7-8987-b2980437e6c6"
            }
            """.utf8
        )

        let health = try JSONDecoder().decode(BridgeHealthDTO.self, from: data)
        #expect(health.protocolVersion == 2)
        #expect(health.voiceInteractionVersion == 2)
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
    func codexFocusPreviewUsesLiveStateAndDeviceConfiguration() throws {
        let state = try JSONDecoder().decode(
            BridgeStateDTO.self,
            from: Data(
                """
                {
                  "time": "23:08",
                  "wifi": true,
                  "battery": null,
                  "active_provider": "codex",
                  "provider": {
                    "id": "codex",
                    "display_name": "Codex",
                    "status": "RUNNING",
                    "project": "M5StickS3",
                    "quota_5h_remaining": null,
                    "quota_7d_remaining": 91,
                    "quota_updated_at": "23:08",
                    "quota_stale": false,
                    "quota_windows": [
                      {
                        "id": "7d",
                        "label": "7D",
                        "remaining_percent": 91,
                        "updated_at": "23:08",
                        "stale": false
                      }
                    ]
                  }
                }
                """.utf8
            )
        )
        let bridge = BridgeSnapshot(
            health: BridgeHealthDTO(
                ok: true,
                bridgeName: "vibestick-bridge",
                bridgeVersion: "0.2.0-dev",
                protocolVersion: 2,
                voiceInteractionVersion: 2,
                bridgeID: "11111111-2222-4333-8444-555555555555"
            ),
            state: state,
            healthEndpointResponded: true,
            errorMessage: nil,
            checkedAt: Date()
        )
        let devices = BridgeDevicesDTO(
            bridgeID: "11111111-2222-4333-8444-555555555555",
            protocolVersion: 2,
            devices: [
                PairedDeviceStatusDTO(
                    deviceID: "vs-001122334455",
                    name: "StickS3",
                    pairedAt: "2026-08-12T12:00:00+08:00",
                    firmwareVersion: "0.2.0-dev",
                    online: true,
                    lastSeenEpoch: 1_000,
                    lastConfigRevision: 1,
                    targetConfigRevision: 1,
                    revoked: false
                )
            ]
        )
        var configuration = DeviceConfiguration.standard
        configuration.buttons.frontDouble = .toggleMute

        let preview = CodexFocusPreviewModel.make(
            bridge: bridge,
            devices: devices,
            configuration: configuration
        )

        #expect(preview.wifiConnected)
        #expect(preview.bridgeConnected)
        #expect(preview.batteryText == "--%")
        #expect(preview.statusKey == "RUNNING")
        #expect(preview.statusText == "运行中")
        #expect(preview.statusTone == .accent)
        #expect(preview.project == "M5StickS3")
        #expect(preview.quotaWindows == [
            CodexFocusPreviewQuotaWindow(id: "7d", label: "7D", remainingPercent: 91, stale: false)
        ])
        #expect(preview.syncHealthy)
        #expect(preview.footerAction == "2X MUTE")
    }

    @Test
    func codexFocusPreviewFailsClosedWhenDeviceIsOffline() {
        let devices = BridgeDevicesDTO(
            bridgeID: "11111111-2222-4333-8444-555555555555",
            protocolVersion: 2,
            devices: [
                PairedDeviceStatusDTO(
                    deviceID: "vs-001122334455",
                    name: "StickS3",
                    pairedAt: "2026-08-12T12:00:00+08:00",
                    firmwareVersion: "0.2.0-dev",
                    online: false,
                    lastSeenEpoch: 1_000,
                    lastConfigRevision: 1,
                    targetConfigRevision: 1,
                    revoked: false
                )
            ]
        )
        var configuration = DeviceConfiguration.standard
        configuration.project.name = "Fixed Project"
        configuration.project.visible = false

        let preview = CodexFocusPreviewModel.make(
            bridge: .empty,
            devices: devices,
            configuration: configuration
        )

        #expect(!preview.wifiConnected)
        #expect(!preview.bridgeConnected)
        #expect(preview.statusKey == "OFFLINE")
        #expect(preview.statusText == "离线")
        #expect(preview.statusTone == .dim)
        #expect(preview.project == nil)
        #expect(!preview.syncHealthy)
    }

    @Test
    func persistedPreferencesContainNoSecretFields() throws {
        var configuration = AppConfiguration.standard
        configuration.asr = .preset(.siliconFlow)
        let data = try JSONEncoder().encode(configuration)
        let json = String(decoding: data, as: UTF8.self).lowercased()
        #expect(!json.contains("token"))
        #expect(!json.contains("api_key"))
        #expect(!json.contains("password"))
        #expect(json.contains("sensevoicesmall"))
    }

    @Test
    func nativeASRPresetsResolveOfficialTranscriptionEndpoints() throws {
        let siliconFlow = try ASRConfiguration.preset(.siliconFlow).validated()
        let groq = try ASRConfiguration.preset(.groq).validated()
        let openAI = try ASRConfiguration.preset(.openAICompatible).validated()

        #expect(siliconFlow.transcriptionURL?.absoluteString == "https://api.siliconflow.cn/v1/audio/transcriptions")
        #expect(siliconFlow.model == "FunAudioLLM/SenseVoiceSmall")
        #expect(groq.transcriptionURL?.absoluteString == "https://api.groq.com/openai/v1/audio/transcriptions")
        #expect(groq.model == "whisper-large-v3-turbo")
        #expect(openAI.transcriptionURL?.absoluteString == "https://api.openai.com/v1/audio/transcriptions")
        #expect(openAI.model == "gpt-4o-mini-transcribe")
    }

    @Test
    func ASRCustomURLAllowsOnlyHTTPSOrLoopbackHTTP() throws {
        var remote = ASRConfiguration.preset(.openAICompatible)
        remote.baseURL = "http://asr.example.test/v1"
        var observed: ASRConfigurationError?
        do {
            _ = try remote.validated()
        } catch {
            observed = error as? ASRConfigurationError
        }

        var local = remote
        local.baseURL = "http://127.0.0.1:8080/v1"
        let validatedLocal = try local.validated()

        #expect(observed == .insecureURL)
        #expect(validatedLocal.transcriptionURL?.absoluteString == "http://127.0.0.1:8080/v1/audio/transcriptions")
        #expect(!validatedLocal.requiresAPIKey)
    }

    @Test
    func olderPreferencesDecodeWithoutNativeASRConfiguration() throws {
        let data = Data(
            """
            {
              "schemaVersion": 1,
              "showMenuBarItem": true,
              "launchAtLogin": false,
              "showTechnicalDetails": false,
              "refreshIntervalSeconds": 15
            }
            """.utf8
        )
        let decoded = try JSONDecoder().decode(AppConfiguration.self, from: data)
        #expect(decoded.asr == nil)
    }

    @Test
    func independentASRTestAcceptsEquivalentFixedTranscript() {
        #expect(ASRTestTranscriptComparator.matches(
            expected: "语音测试成功",
            actual: "语音测试成功。"
        ))
        #expect(ASRTestTranscriptComparator.matches(
            expected: "Vibe Stick test",
            actual: "VIBE-STICK TEST!"
        ))
    }

    @Test
    func independentASRTestRejectsMismatchedFixedTranscript() {
        #expect(!ASRTestTranscriptComparator.matches(
            expected: "语音测试成功",
            actual: "语音配置失败"
        ))
        #expect(!ASRTestTranscriptComparator.matches(expected: "", actual: "anything"))
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
            appPath: "/Library/Application Support/VibeStick/Components.noindex/VibeStick Paste.app",
            requestPath: "/tmp/request.json",
            responsePath: "/tmp/response.json"
        )

        #expect(command.executable == "/usr/bin/open")
        #expect(command.arguments == [
            "-W",
            "-g",
            "-n",
            "/Library/Application Support/VibeStick/Components.noindex/VibeStick Paste.app",
            "--args",
            "--request",
            "/tmp/request.json",
            "--response",
            "/tmp/response.json",
        ])
        #expect(!command.arguments.contains("VibeStickPaste"))

        let unregister = PastePermissionProbeProtocol.unregisterCommand(
            appPath: "/Library/Application Support/VibeStick/Components.noindex/VibeStick Paste.app"
        )
        #expect(unregister.executable.hasSuffix("/lsregister"))
        #expect(unregister.arguments == [
            "-u",
            "/Library/Application Support/VibeStick/Components.noindex/VibeStick Paste.app",
        ])

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
    func pairingRequiresAnIdentifiedM2Bridge() {
        let legacy = BridgeSnapshot(
            health: BridgeHealthDTO(
                ok: true,
                bridgeName: "vibestick-bridge",
                bridgeVersion: "0.1.4",
                protocolVersion: nil,
                voiceInteractionVersion: nil,
                bridgeID: nil
            ),
            state: nil,
            healthEndpointResponded: true,
            errorMessage: nil,
            checkedAt: Date()
        )
        let current = BridgeSnapshot(
            health: BridgeHealthDTO(
                ok: true,
                bridgeName: "vibestick-bridge",
                bridgeVersion: "0.2.0-dev",
                protocolVersion: 2,
                voiceInteractionVersion: 2,
                bridgeID: "90d71007-7734-44f7-8987-b2980437e6c6"
            ),
            state: nil,
            healthEndpointResponded: true,
            errorMessage: nil,
            checkedAt: Date()
        )

        #expect(!legacy.isM2PairingReady)
        #expect(current.isM2PairingReady)
        #expect(DeviceConfiguration.standard.modules == [.codex, .connection])
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
            VIBE_STICK_SEND_MODE=confirm
            """.utf8
        ).write(to: file)
        try Data(
            """
            {
              "schema_version": 2,
              "status": "send_failed",
              "pasted": true,
              "interaction_version": 2,
              "send_mode": "confirm",
              "stopped_at": "2026-08-13T03:09:36",
              "transcript": "must not enter the Swift summary"
            }
            """.utf8
        ).write(to: directory.appendingPathComponent("recording.json"))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        let inspector = ConfigurationInspector(
            environmentFile: file,
            keychainStore: MockSecretStore(present: [.bridgeToken])
        )

        let result = await inspector.inspect()
        #expect(result.legacy.asrConfigurationDetected)
        #expect(result.legacy.asrProvider == "groq")
        #expect(result.legacy.voiceSendMode == .confirm)
        #expect(result.legacy.containsLegacySecrets)
        #expect(result.legacy.legacyFileIsOverexposed)
        #expect(result.keychain.bridgeTokenStored)
        #expect(!result.keychain.asrKeyStored)
        #expect(result.voice.status == "send_failed")
        #expect(result.voice.pasted)
        #expect(result.voice.interactionVersion == 2)
        #expect(result.voice.sendMode == .confirm)
        #expect(result.voice.title == "安全停止：未发送")
        #expect(result.voice.detail.contains("没有按 Return"))
    }

    @Test
    func detectsOnlyEspressifUSBSerialJTAGCandidates() {
        let output = """
        +-o AppleUSBACMData
          "idVendor" = 12346
          "idProduct" = 4097
          "IOTTYSuffix" = "31101"
          +-o IOSerialBSDClient
              "IOCalloutDevice" = "/dev/cu.usbmodem31101"
        """
        let detected = USBDeviceDetectionParser.detect(
            ioregOutput: output,
            ports: ["/dev/cu.usbmodem11101", "/dev/cu.Bluetooth-Incoming-Port", "/dev/cu.usbmodem31101"]
        )

        #expect(detected?.portPath == "/dev/cu.usbmodem31101")
        #expect(detected?.serialNumber == nil)
        #expect(USBDeviceDetectionParser.detect(ioregOutput: output, ports: []) == nil)
        #expect(USBDeviceDetectionParser.detect(
            ioregOutput: output.replacingOccurrences(of: "4097", with: "9999"),
            ports: ["/dev/cu.usbmodem31101"]
        ) == nil)
    }

    @Test
    func serialResponseParserIgnoresLogsAndExtractsOnlyMarkerPayload() {
        let data = Data(
            "I (10) boot: log\nVIBESTICK_RESPONSE {\"command\":\"identify\",\"ok\":true}\nI (20) app: ready\n".utf8
        )
        let payload = SerialResponseParser.responsePayload(in: data)
        #expect(payload == Data(#"{"command":"identify","ok":true}"#.utf8))
        #expect(SerialResponseParser.responsePayload(in: Data("ordinary log\n".utf8)) == nil)
    }

    @Test
    func deviceIdentityDecodesPairingTransactionForLostAckRecovery() throws {
        let identity = try JSONDecoder().decode(
            DeviceIdentity.self,
            from: Data(
                #"{"device_id":"vs-001122334455","model":"M5Stack StickS3","firmware_version":"0.2.0-dev","protocol_version":2,"pairing_id":"90d71007-7734-44f7-8987-b2980437e6c6"}"#.utf8
            )
        )

        #expect(identity.pairingID == "90d71007-7734-44f7-8987-b2980437e6c6")
        #expect(PairingRecovery.confirmsCommittedRotation(
            expectedPairingID: "90d71007-7734-44f7-8987-b2980437e6c6",
            identity: identity
        ))
        #expect(!PairingRecovery.confirmsCommittedRotation(
            expectedPairingID: "11111111-2222-3333-4444-555555555555",
            identity: identity
        ))
    }

    @Test
    func pairingHashMatchesBridgeProtocolVector() {
        let salt = Data([
            0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef,
            0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef,
        ])
        #expect(
            PairingMaterial.tokenHash(salt: salt, token: String(repeating: "a", count: 43))
                == "fac5f1435e66c70021e14689ba2043a3a9c992d87ac674e5f1386c5482f9c5ba"
        )
    }

    @Test
    func pairingRotationStagesASeparateKeychainItem() {
        let oldRecord = PairedDeviceRecord(
            deviceID: "vs-001122334455",
            name: "StickS3",
            tokenSalt: String(repeating: "1", count: 32),
            tokenHash: String(repeating: "2", count: 64),
            pairedAt: "2026-08-11T20:24:45Z",
            firmwareVersion: "0.2.0-dev",
            revoked: false
        )
        let plan = PairingKeychainMigrationPlan.make(
            deviceID: oldRecord.deviceID,
            pairingID: "90d71007-7734-44f7-8987-b2980437e6c6",
            existingRecord: oldRecord
        )

        #expect(plan.previousAccount == "device-token.vs-001122334455")
        #expect(plan.newAccount == "device-token.v2.vs-001122334455.90d71007-7734-44f7-8987-b2980437e6c6")
        #expect(plan.previousAccount != plan.newAccount)
    }

    @Test
    func failedUSBRotationRestoresRegistryAndRemovesOnlyStagedSecret() async throws {
        let oldRecord = PairedDeviceRecord(
            deviceID: "vs-001122334455",
            name: "StickS3",
            tokenSalt: String(repeating: "1", count: 32),
            tokenHash: String(repeating: "2", count: 64),
            pairedAt: "2026-08-11T20:24:45Z",
            firmwareVersion: "0.2.0-dev",
            revoked: false
        )
        let registry = MockPairingRegistry(record: oldRecord)
        let tokens = MockPairingTokenStore(
            accounts: ["device-token.vs-001122334455": Data("old-token".utf8)]
        )
        let manager = DevicePairingManager(
            serialClient: RejectingPairingSerialClient(),
            registryStore: registry,
            identityStore: FixedPairingBridgeIdentityStore(),
            keychainStore: tokens
        )

        do {
            _ = try await manager.pair(
                candidate: USBDeviceCandidate(
                    portPath: "/dev/cu.usbmodem-test",
                    serialNumber: nil,
                    vendorID: USBDeviceCandidate.esp32S3VendorID,
                    productID: USBDeviceCandidate.usbSerialJTAGProductID
                ),
                fallbackHost: "192.0.2.10"
            )
            Issue.record("Expected the injected USB write failure")
        } catch PairingError.serialWriteFailed {
            // Expected: exercise the transaction rollback after staging.
        }

        #expect(await registry.currentRecord() == oldRecord)
        #expect(tokens.accountNames() == ["device-token.vs-001122334455"])
    }

    @Test
    func manualFallbackAddressRejectsURLsAndPorts() throws {
        #expect(try ManualBridgeAddressValidator.normalized("192.0.2.10") == "192.0.2.10")
        #expect(try ManualBridgeAddressValidator.normalized("VibeStick-Mac.local") == "vibestick-mac.local")
        #expect(try ManualBridgeAddressValidator.normalized("  ") == nil)
        #expect(throws: ManualBridgeAddressError.self) {
            try ManualBridgeAddressValidator.normalized("http://192.0.2.10:8765")
        }
    }

    @Test
    func deviceConfigurationIsNormalizedVersionedAndPrivate() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VibeStickDeviceConfigTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("device-config-v1.json")
        let store = DeviceConfigurationStore(fileURL: file)
        var requested = DeviceConfiguration.standard
        requested.modules = [.claude]
        requested.project.name = String(repeating: "x", count: 80)

        let saved = try await store.save(requested)
        let loaded = await store.load()
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        let raw = try String(contentsOf: file, encoding: .utf8).lowercased()

        #expect(saved.revision == 1)
        #expect(loaded.modules == [.codex, .claude, .connection])
        #expect(loaded.project.name.count == 18)
        #expect(permissions?.intValue == 0o600)
        #expect(!raw.contains("token"))
        #expect(!raw.contains("password"))
        #expect(!raw.contains("api_key"))
    }

    @Test
    func projectNameRespectsFirmwareCharacterAndByteLimits() {
        var latin = DeviceConfiguration.standard
        latin.project.name = "abcdefghijklmnopqrstuvwxyz"
        var chinese = DeviceConfiguration.standard
        chinese.project.name = "这是一个长度超过固件字节限制的项目名称"

        #expect(latin.normalized.project.name == "abcdefghijklmnopqr")
        #expect(chinese.normalized.project.name.utf8.count < 40)
    }
}

private struct MockSecretStore: SecretStoring {
    let present: Set<KeychainSecret>

    func contains(_ key: KeychainSecret) -> Bool {
        present.contains(key)
    }
}

private actor MockPairingRegistry: PairingRegistryStoring {
    private var storedRecord: PairedDeviceRecord?

    init(record: PairedDeviceRecord?) {
        storedRecord = record
    }

    func record(for deviceID: String) -> PairedDeviceRecord? {
        storedRecord?.deviceID == deviceID ? storedRecord : nil
    }

    func upsert(_ record: PairedDeviceRecord) {
        storedRecord = record
    }

    func remove(deviceID: String) {
        if storedRecord?.deviceID == deviceID { storedRecord = nil }
    }

    func currentRecord() -> PairedDeviceRecord? {
        storedRecord
    }
}

private final class MockPairingTokenStore: PairingTokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var accounts: [String: Data]

    init(accounts: [String: Data]) {
        self.accounts = accounts
    }

    func write(_ data: Data, account: String) {
        lock.withLock { accounts[account] = data }
    }

    func delete(account: String) {
        lock.withLock { accounts.removeValue(forKey: account) }
    }

    func accountNames() -> [String] {
        lock.withLock { accounts.keys.sorted() }
    }
}

private actor RejectingPairingSerialClient: DeviceSerialPairing {
    func identify(portPath: String) -> DeviceIdentity {
        DeviceIdentity(
            deviceID: "vs-001122334455",
            model: "M5Stack StickS3",
            firmwareVersion: "0.2.0-dev",
            protocolVersion: 2,
            pairingID: nil
        )
    }

    func pair(
        identity: DeviceIdentity,
        material: PairingMaterial,
        bridgeID: String,
        fallbackHost: String,
        portPath: String
    ) throws {
        throw PairingError.serialWriteFailed
    }
}

private actor FixedPairingBridgeIdentityStore: PairingBridgeIdentityStoring {
    func bridgeID() -> String {
        "11111111-2222-4333-8444-555555555555"
    }
}
