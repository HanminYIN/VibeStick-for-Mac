import CryptoKit
import Foundation
import Security
import Testing

struct VibeStickAppTests {
    @Test
    func automaticRefreshNeverEnumeratesUSB() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("VibeStickApp/App/AppModel.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        let refreshStart = try #require(text.range(of: "    func refresh(forcePermissionCheck:"))
        let refreshEnd = try #require(
            text.range(of: "    func refreshManagedRuntimeStatus", range: refreshStart.upperBound..<text.endIndex)
        )
        let automaticRefresh = text[refreshStart.lowerBound..<refreshEnd.lowerBound]
        let explicitStart = try #require(text.range(of: "    func detectUSBDevice()"))
        let explicitEnd = try #require(
            text.range(of: "    @discardableResult", range: explicitStart.upperBound..<text.endIndex)
        )
        let explicitDetection = text[explicitStart.lowerBound..<explicitEnd.lowerBound]

        #expect(!automaticRefresh.contains("usbDeviceDetector"))
        #expect(explicitDetection.contains("usbDeviceDetector.detect()"))
    }

    @Test
    func appModelRoutesASRStartupAndSaveThroughManagedSettingsBoundary() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("VibeStickApp/App/AppModel.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        let start = try #require(text.range(of: "    func start()"))
        let startEnd = try #require(
            text.range(of: "    func requestRefresh", range: start.upperBound..<text.endIndex)
        )
        let save = try #require(text.range(of: "    func saveASRConfiguration"))
        let saveEnd = try #require(
            text.range(of: "    func deleteASRAPIKey", range: save.upperBound..<text.endIndex)
        )

        #expect(text[start.lowerBound..<startEnd.lowerBound]
            .contains("managedASRSettingsStore.loadConfigurationIfManaged()"))
        #expect(text[save.lowerBound..<saveEnd.lowerBound]
            .contains("managedASRSettingsStore.saveIfManaged"))
    }

    @Test
    func runtimeInstallerAllowsTimeForLocalNetworkPermissionHandoff() {
        let verificationMilliseconds =
            RuntimeLaunchAgentInstallController.serviceVerificationAttempts
            * RuntimeLaunchAgentInstallController.serviceVerificationIntervalMilliseconds
        #expect(verificationMilliseconds >= 120_000)
    }

    @Test
    func freshRuntimeBootstrapCreatesPrivateManagedBridgeCredentialAndRollsBackOwnedState() async throws {
        let root = temporaryTestDirectory("FreshRuntimeBootstrap")
        defer { try? FileManager.default.removeItem(at: root) }
        let supportDirectory = root.appendingPathComponent("Support", isDirectory: true)
        let vault = FictionalRuntimeBootstrapCredentialVault()
        let fictionalToken = Data("fixture-bridge-token-with-32-bytes-minimum".utf8)
        let bootstrapper = RuntimeFreshInstallConfigurationBootstrapper(
            supportDirectory: supportDirectory,
            credentialVault: vault,
            tokenGenerator: { fictionalToken }
        )

        let receipt = try await bootstrapper.prepareIfNeeded()
        let configurationURL = supportDirectory.appendingPathComponent("managed-runtime-v1.json")
        let configurationData = try Data(contentsOf: configurationURL)
        let configuration = try JSONDecoder().decode(
            M4ManagedRuntimeConfiguration.self,
            from: configurationData
        ).validated()
        let bridgeReference = M4VersionedCredentialReference.managed(.bridgeToken)
        let permissions = try #require(
            try FileManager.default.attributesOfItem(atPath: configurationURL.path)[.posixPermissions]
                as? NSNumber
        ).intValue & 0o777

        #expect(receipt.createdManagedConfiguration)
        #expect(receipt.createdBridgeCredential)
        #expect(configuration.credentialReferences == [bridgeReference])
        #expect(configuration.agentProvider == "auto")
        #expect(configuration.voiceDelivery?.sendMode == "paste_only")
        #expect(!configurationData.contains(fictionalToken))
        #expect(permissions == 0o600)
        #expect(await vault.read(bridgeReference) == fictionalToken)

        try await bootstrapper.rollback(receipt)

        #expect(!FileManager.default.fileExists(atPath: configurationURL.path))
        #expect(await vault.read(bridgeReference) == nil)
        #expect(await vault.legacyAccountsRemainUntouched())
    }

    @Test
    func managedASRSettingsSaveUpdatesOnlyManagedDocumentAndFixedCredential() async throws {
        let root = temporaryTestDirectory("ManagedASRSettings")
        defer { try? FileManager.default.removeItem(at: root) }
        let configurationURL = root.appendingPathComponent("managed-runtime-v1.json")
        let bridgeReference = M4VersionedCredentialReference.managed(.bridgeToken)
        let asrReference = M4VersionedCredentialReference.managed(.asrAPIKey)
        let original = try M4ManagedRuntimeConfiguration(
            schemaVersion: M4ManagedRuntimeConfiguration.currentSchemaVersion,
            credentialReferences: [bridgeReference],
            asr: nil,
            agentProvider: "auto",
            projectPresentation: nil,
            voiceDelivery: M4ManagedVoiceDelivery(sendMode: "paste_only"),
            soundEnabled: nil
        ).validated()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(original).write(to: configurationURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: configurationURL.path
        )
        let client = FictionalManagedASRGenericPasswordClient(items: [
            bridgeReference: Data("fixture-bridge-secret".utf8),
        ])
        let store = M4ManagedASRSettingsStore(
            configurationURL: configurationURL,
            credentialClient: client
        )
        let fictionalASRKey = "fixture-managed-asr-secret"
        let requested = try ASRConfiguration.preset(.groq).validated()

        #expect(try await store.saveIfManaged(requested, apiKey: fictionalASRKey))

        let savedData = try Data(contentsOf: configurationURL)
        let saved = try JSONDecoder().decode(
            M4ManagedRuntimeConfiguration.self,
            from: savedData
        ).validated()
        let permissions = try #require(
            try FileManager.default.attributesOfItem(atPath: configurationURL.path)[.posixPermissions]
                as? NSNumber
        ).intValue & 0o777
        #expect(saved.asr?.provider == "groq")
        #expect(saved.asr?.model == requested.model)
        #expect(saved.credentialReferences == [bridgeReference, asrReference])
        #expect(!savedData.contains(Data(fictionalASRKey.utf8)))
        #expect(permissions == 0o600)
        #expect(await client.value(for: bridgeReference) == Data("fixture-bridge-secret".utf8))
        #expect(await client.value(for: asrReference) == Data(fictionalASRKey.utf8))
        #expect(try await store.loadConfigurationIfManaged() == requested)

        let lookup = try await store.storedAPIKeyIfManaged()
        #expect(lookup.isManaged)
        #expect(lookup.apiKey == fictionalASRKey)
        #expect(try await store.deleteAPIKeyIfManaged())
        #expect(await client.value(for: asrReference) == nil)

        await client.resetReadReferences()
        var local = ASRConfiguration.preset(.localCommand)
        local.localCommand = "/usr/bin/fixture-transcriber"
        #expect(try await store.saveIfManaged(local, apiKey: ""))
        #expect(await client.readReferences.isEmpty)
    }

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
    func ASRKeychainAccessAddsOnlyTheAppleSecurityTool() {
        #expect(
            KeychainAccessPolicy.asrAdditionalTrustedApplicationPaths
                == ["/usr/bin/security"]
        )
        let updateAttributes = KeychainAccessPolicy.existingItemUpdateAttributes(data: Data())
        #expect(Set(updateAttributes.keys) == Set([kSecValueData as String]))
        #expect(updateAttributes[kSecAttrAccess as String] == nil)
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
    func M4MaintenancePlanIsReadyWhenAllComponentsAreHealthy() {
        let plan = RuntimeMaintenancePlanner.make(from: runtimeSnapshot())
        #expect(plan.phase == .ready)
        #expect(plan.actions.isEmpty)
        #expect(plan.allowsPayloadInstall)
    }

    @Test
    func M4MaintenancePlanInstallsOnlyMissingComponents() {
        let snapshot = runtimeSnapshot(
            bridge: component(.bridge, phase: .notInstalled, installed: false),
            paste: component(.paste, phase: .notInstalled, installed: false)
        )
        let plan = RuntimeMaintenancePlanner.make(from: snapshot)
        #expect(plan.phase == .installationRequired)
        #expect(plan.actions == [.installBridge, .installPaste])
    }

    @Test
    func M4MaintenancePlanRepairsBrokenComponentsWithoutReinstallingHealthyOnes() {
        let snapshot = runtimeSnapshot(
            hud: component(.hud, phase: .versionMismatch),
            paste: component(.paste, phase: .needsRepair)
        )
        let plan = RuntimeMaintenancePlanner.make(from: snapshot)
        #expect(plan.phase == .repairRequired)
        #expect(plan.actions == [.repairHUD, .repairPaste])
    }

    @Test
    func M4MaintenancePlanTreatsPastePermissionAsAuthorizationOnly() {
        let snapshot = runtimeSnapshot(
            paste: component(.paste, phase: .permissionMissing)
        )
        let plan = RuntimeMaintenancePlanner.make(from: snapshot)
        #expect(plan.phase == .permissionRequired)
        #expect(plan.actions == [.grantPastePermission])
        #expect(!plan.actions.contains(.repairPaste))
    }

    @Test
    func M4MaintenancePlanStartsInstalledStoppedServices() {
        let snapshot = runtimeSnapshot(
            bridge: component(.bridge, phase: .stopped),
            hud: component(.hud, phase: .stopped)
        )
        let plan = RuntimeMaintenancePlanner.make(from: snapshot)
        #expect(plan.phase == .startRequired)
        #expect(plan.actions == [.startBridge, .startHUD])
    }

    @Test
    func M4MaintenancePlanBlocksWhileRecording() {
        let plan = RuntimeMaintenancePlanner.make(from: runtimeSnapshot(recording: true))
        #expect(plan.phase == .blocked)
        #expect(plan.actions == [.waitForRecording])
        #expect(!plan.allowsPayloadInstall)
    }

    @Test
    func M4MaintenancePlanBlocksUnknownPortOwner() {
        let snapshot = runtimeSnapshot(
            bridge: component(
                .bridge,
                phase: .portConflict,
                ownership: .conflictingProcess
            )
        )
        let plan = RuntimeMaintenancePlanner.make(from: snapshot)
        #expect(plan.phase == .blocked)
        #expect(plan.actions == [.resolvePortConflict])
    }

    @Test
    func M4MaintenancePlanNeverTakesOverExternalBridge() {
        let snapshot = runtimeSnapshot(
            bridge: component(
                .bridge,
                phase: .healthy,
                installed: false,
                ownership: .externalProcess
            )
        )
        let plan = RuntimeMaintenancePlanner.make(from: snapshot)
        #expect(plan.phase == .blocked)
        #expect(plan.actions == [.preserveExternalBridge])
    }

    @Test
    func M4MaintenancePlanWaitsForCompleteInspection() {
        let snapshot = runtimeSnapshot(
            bridge: component(.bridge, phase: .unknown),
            checkedAt: .distantPast
        )
        let plan = RuntimeMaintenancePlanner.make(from: snapshot)
        #expect(plan.phase == .checking)
        #expect(plan.actions.isEmpty)
    }

    private func component(
        _ kind: ComponentKind,
        phase: ServicePhase = .healthy,
        installed: Bool = true,
        ownership: RuntimeOwnership = .legacyLaunchAgent
    ) -> ComponentHealth {
        ComponentHealth(
            kind: kind,
            phase: phase,
            detail: phase.label,
            isInstalled: installed,
            ownership: ownership
        )
    }

    private func runtimeSnapshot(
        bridge: ComponentHealth? = nil,
        hud: ComponentHealth? = nil,
        paste: ComponentHealth? = nil,
        recording: Bool = false,
        checkedAt: Date = Date(timeIntervalSince1970: 1_000)
    ) -> RuntimeSnapshot {
        RuntimeSnapshot(
            bridge: bridge ?? component(.bridge),
            hud: hud ?? component(.hud),
            paste: paste ?? component(.paste),
            isRecordingActive: recording,
            checkedAt: checkedAt
        )
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
        #expect(result.legacyKeychain.bridgeTokenStored)
        #expect(!result.legacyKeychain.asrKeyStored)
        #expect(result.voice.status == "send_failed")
        #expect(result.voice.pasted)
        #expect(result.voice.interactionVersion == 2)
        #expect(result.voice.sendMode == .confirm)
        #expect(result.voice.title == "安全停止：未发送")
        #expect(result.voice.detail.contains("没有按 Return"))
    }

    @Test
    func managedRuntimeStatusDoesNotQueryKeychainWithoutAConfiguration() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VibeStick-M4-5H-Absent-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let checker = MockManagedCredentialPresenceChecker(present: [])
        let inspector = M4ManagedRuntimeStatusInspector(
            configurationReader: M4FoundationManagedRuntimeConfigurationReader(
                fileURL: directory.appendingPathComponent("fictional-managed-runtime.json")
            ),
            credentialPresenceChecker: checker
        )

        let result = await inspector.inspect()

        #expect(result == .empty)
        #expect(await checker.checkedReferences.isEmpty)
    }

    @Test
    func managedRuntimeStatusValidatesReferencesAndQueriesOnlyPresence() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VibeStick-M4-5H-Stored-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("fictional-managed-runtime.json")
        let configuration = m4HManagedRuntimeConfigurationFixture()
        try JSONEncoder().encode(configuration).write(to: file)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: file.path
        )
        let expectedReferences = Set(configuration.credentialReferences)
        let checker = MockManagedCredentialPresenceChecker(present: expectedReferences)
        let inspector = M4ManagedRuntimeStatusInspector(
            configurationReader: M4FoundationManagedRuntimeConfigurationReader(fileURL: file),
            credentialPresenceChecker: checker
        )

        let result = await inspector.inspect()

        #expect(result.configurationState == .validated)
        #expect(result.bridgeCredentialState == .stored)
        #expect(result.asrCredentialState == .stored)
        #expect(result.hasStoredReferencedCredentials)
        #expect(!result.requiresAttention)
        let checkedReferences = await checker.checkedReferences
        #expect(Set(checkedReferences) == expectedReferences)
    }

    @Test
    func managedRuntimeStatusReportsAMissingReferencedCredentialWithoutReadingIt() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VibeStick-M4-5H-Missing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("fictional-managed-runtime.json")
        let configuration = m4HManagedRuntimeConfigurationFixture()
        try JSONEncoder().encode(configuration).write(to: file)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: file.path
        )
        let checker = MockManagedCredentialPresenceChecker(
            present: [.managed(.asrAPIKey)]
        )
        let inspector = M4ManagedRuntimeStatusInspector(
            configurationReader: M4FoundationManagedRuntimeConfigurationReader(fileURL: file),
            credentialPresenceChecker: checker
        )

        let result = await inspector.inspect()

        #expect(result.configurationState == .validated)
        #expect(result.bridgeCredentialState == .missing)
        #expect(result.asrCredentialState == .stored)
        #expect(!result.hasStoredReferencedCredentials)
        #expect(result.requiresAttention)
    }

    @Test
    func managedRuntimeStatusFailsClosedAndKeepsInvalidInputOutOfTheSummary() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VibeStick-M4-5H-Invalid-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("fictional-managed-runtime.json")
        let privateValue = "fixture-private-value-must-not-escape"
        let privatePath = "/fictional/private/location"
        try Data(
            "{\"schemaVersion\":99,\"private\":\"\(privateValue)\",\"path\":\"\(privatePath)\"}".utf8
        ).write(to: file)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: file.path
        )
        let checker = MockManagedCredentialPresenceChecker(present: [])
        let inspector = M4ManagedRuntimeStatusInspector(
            configurationReader: M4FoundationManagedRuntimeConfigurationReader(fileURL: file),
            credentialPresenceChecker: checker
        )

        let result = await inspector.inspect()
        let reflected = String(reflecting: result)

        #expect(result.configurationState == .invalid)
        #expect(result.bridgeCredentialState == .notReferenced)
        #expect(result.asrCredentialState == .notReferenced)
        #expect(await checker.checkedReferences.isEmpty)
        #expect(!reflected.contains(privateValue))
        #expect(!reflected.contains(privatePath))
        #expect(!reflected.contains("bridge-token-v1"))
        #expect(!reflected.contains("asr-api-key-v1"))
    }

    @Test
    func managedRuntimeReaderRejectsAnOverexposedFictionalFileBeforeKeychainChecks() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VibeStick-M4-5H-Permissions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("fictional-managed-runtime.json")
        try JSONEncoder().encode(m4HManagedRuntimeConfigurationFixture()).write(to: file)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: file.path
        )
        let checker = MockManagedCredentialPresenceChecker(present: [])
        let inspector = M4ManagedRuntimeStatusInspector(
            configurationReader: M4FoundationManagedRuntimeConfigurationReader(fileURL: file),
            credentialPresenceChecker: checker
        )

        let result = await inspector.inspect()

        #expect(result.configurationState == .unavailable)
        #expect(await checker.checkedReferences.isEmpty)
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
        #expect(identity.pairingSchemaVersion == nil)
        #expect(identity.wifiConfigured == nil)
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
    func pairingSchemaTwoCarriesValidatedWiFiWithoutChangingLegacyPayloads() throws {
        let identity = DeviceIdentity(
            deviceID: "vs-001122334455",
            model: "M5Stack StickS3",
            firmwareVersion: "0.2.0-dev",
            protocolVersion: 2,
            pairingID: nil,
            pairingSchemaVersion: 2,
            wifiConfigured: false
        )
        let material = PairingMaterial(
            token: String(repeating: "a", count: 43),
            tokenSalt: String(repeating: "1", count: 32),
            tokenHash: String(repeating: "2", count: 64),
            pairingID: "90d71007-7734-44f7-8987-b2980437e6c6"
        )
        let credentials = try WiFiProvisioningCredentials(ssid: "中文 Wi-Fi", password: "valid-passphrase")
        let versionTwo = DevicePairingPayload(
            identity: identity,
            material: material,
            bridgeID: "11111111-2222-4333-8444-555555555555",
            fallbackHost: "192.0.2.10",
            wifiCredentials: credentials
        )
        let versionOne = DevicePairingPayload(
            identity: identity,
            material: material,
            bridgeID: "11111111-2222-4333-8444-555555555555",
            fallbackHost: "192.0.2.10",
            wifiCredentials: nil
        )
        let v2JSON = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(versionTwo)) as? [String: Any])
        let v1JSON = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(versionOne)) as? [String: Any])

        #expect(v2JSON["schema_version"] as? Int == 2)
        #expect(v2JSON["wifi_ssid"] as? String == "中文 Wi-Fi")
        #expect(v2JSON["wifi_password"] as? String == "valid-passphrase")
        #expect(v1JSON["schema_version"] as? Int == 1)
        #expect(v1JSON["wifi_ssid"] == nil)
        #expect(v1JSON["wifi_password"] == nil)
        #expect(throws: PairingError.self) {
            _ = try WiFiProvisioningCredentials(ssid: "", password: "valid-passphrase")
        }
        #expect(throws: PairingError.self) {
            _ = try WiFiProvisioningCredentials(ssid: "Wi-Fi", password: "short")
        }
    }

    @Test
    func wifiProvisioningDraftPreservesExistingConfigurationOnlyWhenBothFieldsAreEmpty() throws {
        #expect(try WiFiProvisioningDraft(ssid: "", password: "").validatedCredentials() == nil)

        let validated = try WiFiProvisioningDraft(
            ssid: "VibeStick 2.4G",
            password: "valid-passphrase"
        ).validatedCredentials()
        let credentials = try #require(validated)
        #expect(credentials.ssid == "VibeStick 2.4G")
        #expect(credentials.password == "valid-passphrase")

        do {
            _ = try WiFiProvisioningDraft(
                ssid: "VibeStick 2.4G",
                password: ""
            ).validatedCredentials()
            Issue.record("Expected a partial Wi-Fi draft to fail closed")
        } catch PairingError.incompleteWiFiCredentials {
            // Expected: never infer whether a blank field should be preserved or replaced.
        }
    }

    @Test
    func unconfiguredSchemaTwoRequiresWiFiBeforeStagingPairingState() async throws {
        let serial = UnconfiguredSchemaTwoPairingSerialClient()
        let registry = MockPairingRegistry(record: nil)
        let tokens = MockPairingTokenStore(accounts: [:])
        let manager = DevicePairingManager(
            serialClient: serial,
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
            Issue.record("Expected first Wi-Fi provisioning to be required")
        } catch PairingError.wifiCredentialsRequired {
            // Expected: this happens before registry, Keychain, or USB pair mutation.
        }

        #expect(await serial.pairAttemptCount() == 0)
        #expect(await registry.currentRecord() == nil)
        #expect(tokens.accountNames().isEmpty)
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

    @Test
    func runtimePayloadManifestRejectsTamperingAndExtraFiles() throws {
        let root = temporaryTestDirectory("PayloadTamper")
        defer { try? FileManager.default.removeItem(at: root) }
        try makeRuntimePayload(at: root)
        _ = try RuntimePayloadValidator.validate(root: root)

        let main = root.appendingPathComponent("Components.noindex/VibeStick Bridge.app/Contents/MacOS/VibeStickBridge")
        try Data("tampered".utf8).write(to: main)
        #expect(throws: RuntimeInstallError.self) {
            try RuntimePayloadValidator.validate(root: root)
        }

        try makeRuntimePayload(at: root, replaceExisting: true)
        try Data("extra".utf8).write(to: root.appendingPathComponent("unexpected.txt"))
        #expect(throws: RuntimeInstallError.self) {
            try RuntimePayloadValidator.validate(root: root)
        }
    }

    @Test
    func runtimePayloadManifestRejectsSymlinksAndTraversal() throws {
        let root = temporaryTestDirectory("PayloadPaths")
        defer { try? FileManager.default.removeItem(at: root) }
        try makeRuntimePayload(at: root)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("Components.noindex/link"),
            withDestinationURL: root.appendingPathComponent("Components.noindex/VibeStick Bridge.app")
        )
        #expect(throws: RuntimeInstallError.self) {
            try RuntimePayloadValidator.validate(root: root)
        }

        try FileManager.default.removeItem(at: root.appendingPathComponent("Components.noindex/link"))
        let manifestURL = root.appendingPathComponent(RuntimePayloadValidator.manifestName)
        var manifest = try JSONDecoder().decode(
            RuntimePayloadManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        manifest = RuntimePayloadManifest(
            schemaVersion: manifest.schemaVersion,
            payloadVersion: manifest.payloadVersion,
            files: manifest.files + [
                RuntimePayloadFile(
                    path: "../escape",
                    sha256: String(repeating: "0", count: 64),
                    size: 0,
                    mode: 0o600
                )
            ]
        )
        try JSONEncoder().encode(manifest).write(to: manifestURL)
        #expect(throws: RuntimeInstallError.self) {
            try RuntimePayloadValidator.validate(root: root)
        }
    }

    @Test
    func firmwarePayloadValidatorPinsImagesGeometryAndNVSRange() throws {
        let root = temporaryTestDirectory("FirmwarePayload")
        defer { try? FileManager.default.removeItem(at: root) }
        try makeFirmwarePayload(at: root)

        let validated = try FirmwarePayloadValidator.validate(root: root)

        #expect(validated.target == "esp32s3")
        #expect(validated.flash.size == 8 * 1024 * 1024)
        #expect(validated.preservedRanges == [FirmwarePayloadValidator.preservedNVS])
        #expect(Dictionary(uniqueKeysWithValues: validated.files.map { ($0.path, $0.offset) })
            == FirmwarePayloadValidator.requiredOffsets)
    }

    @Test
    func firmwarePayloadValidatorRejectsTamperingExtraFilesAndNVSOverlap() throws {
        let root = temporaryTestDirectory("FirmwarePayloadTamper")
        defer { try? FileManager.default.removeItem(at: root) }
        try makeFirmwarePayload(at: root)
        try Data("tampered".utf8).write(to: root.appendingPathComponent("vibe-stick.bin"))
        #expect(throws: FirmwarePayloadError.self) {
            try FirmwarePayloadValidator.validate(root: root)
        }

        try makeFirmwarePayload(at: root, replaceExisting: true)
        try writeTestFile("extra", to: root.appendingPathComponent("unexpected.bin"))
        #expect(throws: FirmwarePayloadError.self) {
            try FirmwarePayloadValidator.validate(root: root)
        }

        try makeFirmwarePayload(at: root, replaceExisting: true)
        let manifestURL = root.appendingPathComponent(FirmwarePayloadValidator.manifestName)
        let original = try JSONDecoder().decode(
            FirmwarePayloadManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        let changedFiles = original.files.map { entry in
            entry.path == "partition-table.bin"
                ? FirmwarePayloadFile(
                    mode: entry.mode,
                    offset: 0x9000,
                    path: entry.path,
                    sha256: entry.sha256,
                    size: entry.size
                )
                : entry
        }
        let changed = FirmwarePayloadManifest(
            board: original.board,
            files: changedFiles,
            flash: original.flash,
            payloadVersion: original.payloadVersion,
            preservedRanges: original.preservedRanges,
            schemaVersion: original.schemaVersion,
            source: original.source,
            target: original.target
        )
        try JSONEncoder().encode(changed).write(to: manifestURL)
        #expect(throws: FirmwarePayloadError.self) {
            try FirmwarePayloadValidator.validate(root: root)
        }
    }

    @Test
    func runtimeInstallerSwitchesManagedTargetsAndPreservesPrivateConfiguration() async throws {
        let fixture = try makeRuntimeInstallFixture("InstallSuccess")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let controller = MockRuntimeInstallController(preservePaste: false)
        let installer = RuntimeInstaller(
            layout: fixture.layout,
            payloadRoot: fixture.payload,
            serviceController: controller,
            configurationBootstrapper: MockRuntimeConfigurationBootstrapper()
        )

        let receipt = try await installer.install()

        #expect(!FileManager.default.fileExists(atPath: fixture.layout.runtimeDirectory.path))
        #expect(try String(contentsOf: fixture.layout.bridgeApp.appendingPathComponent("Contents/MacOS/VibeStickBridge"), encoding: .utf8) == "new-bridge")
        #expect(try String(contentsOf: fixture.privateConfiguration, encoding: .utf8) == "do-not-touch")
        #expect(try String(contentsOf: receipt.backupDirectory.appendingPathComponent("managed/support/runtime/bridge/version.txt"), encoding: .utf8) == "old-runtime")
        #expect(FileManager.default.fileExists(atPath: receipt.backupDirectory.appendingPathComponent("install-receipt-v1.json").path))
        let bridgeAgentData = try Data(contentsOf: fixture.layout.bridgeLaunchAgent)
        let bridgeAgentValue = try PropertyListSerialization.propertyList(
            from: bridgeAgentData,
            format: nil
        )
        let bridgeAgent = try #require(bridgeAgentValue as? [String: Any])
        #expect(
            bridgeAgent["AssociatedBundleIdentifiers"] as? [String]
                == ["io.github.hanminyin.vibestick"]
        )
        let events = await controller.recordedEvents()
        #expect(events == ["preflight", "validate", "paste", "revalidate", "stop", "start", "verify"])
    }

    @Test(arguments: [RuntimeInstallFault.afterBackup, .afterSwitch, .afterStart])
    func runtimeInstallerRollsBackAtEveryMutationFault(fault: RuntimeInstallFault) async throws {
        let fixture = try makeRuntimeInstallFixture("Rollback-\(fault.rawValue)")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let controller = MockRuntimeInstallController(preservePaste: false)
        let installer = RuntimeInstaller(
            layout: fixture.layout,
            payloadRoot: fixture.payload,
            serviceController: controller,
            configurationBootstrapper: MockRuntimeConfigurationBootstrapper()
        )

        do {
            _ = try await installer.install(fault: fault)
            Issue.record("Expected injected fault \(fault.rawValue)")
        } catch let error as RuntimeInstallError {
            #expect(error.localizedDescription.contains("旧运行时和原服务状态已恢复"))
        }

        #expect(try String(contentsOf: fixture.layout.runtimeDirectory.appendingPathComponent("bridge/version.txt"), encoding: .utf8) == "old-runtime")
        #expect(try String(contentsOf: fixture.layout.bridgeApp.appendingPathComponent("Contents/MacOS/VibeStickBridge"), encoding: .utf8) == "old-bridge")
        #expect(try String(contentsOf: fixture.layout.bridgeLaunchAgent, encoding: .utf8) == "old-bridge-plist")
        #expect(try String(contentsOf: fixture.privateConfiguration, encoding: .utf8) == "do-not-touch")
        let restored = await controller.didRestore(
            RuntimeServiceCheckpoint(
                bridgeWasLoaded: true,
                bridgeWasRunning: true,
                hudWasLoaded: true,
                hudWasRunning: true
            )
        )
        #expect(restored)
    }

    @Test
    func runtimeInstallerKeepsUnchangedPasteIdentityInPlace() async throws {
        let fixture = try makeRuntimeInstallFixture("PreservePaste")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let existingPaste = fixture.layout.pasteApp.appendingPathComponent("Contents/MacOS/VibeStickPaste")
        let controller = MockRuntimeInstallController(preservePaste: true)
        let installer = RuntimeInstaller(
            layout: fixture.layout,
            payloadRoot: fixture.payload,
            serviceController: controller,
            configurationBootstrapper: MockRuntimeConfigurationBootstrapper()
        )

        let receipt = try await installer.install()

        #expect(receipt.preservedPasteIdentity)
        #expect(try String(contentsOf: existingPaste, encoding: .utf8) == "old-paste")
        #expect(try String(contentsOf: receipt.backupDirectory.appendingPathComponent("managed/support/Components.noindex/VibeStick Paste.app/Contents/MacOS/VibeStickPaste"), encoding: .utf8) == "old-paste")
    }

    @Test
    func runtimeInstallerBootstrapsBeforeStartAndRollsBackConfigurationAfterStartFailure() async throws {
        let fixture = try makeRuntimeInstallFixture("BootstrapTransaction")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let trace = RuntimeInstallEventTrace()
        let controller = MockRuntimeInstallController(preservePaste: false, trace: trace)
        let bootstrapper = MockRuntimeConfigurationBootstrapper(trace: trace)
        let installer = RuntimeInstaller(
            layout: fixture.layout,
            payloadRoot: fixture.payload,
            serviceController: controller,
            configurationBootstrapper: bootstrapper
        )

        do {
            _ = try await installer.install(fault: .afterStart)
            Issue.record("Expected injected post-start failure")
        } catch is RuntimeInstallError {
            // Expected: the public outcome is the installer's fixed transaction failure.
        }

        #expect(
            trace.events == [
                "preflight", "validate", "paste", "revalidate", "stop",
                "bootstrap", "start", "bootstrap-rollback", "stop", "restore",
            ]
        )
    }

    @Test
    func flashingToolDescriptorRejectsInsecureOrUnboundedSources() throws {
        let data = Data("fixture-tool".utf8)
        let insecure = makeFlashingToolDescriptor(
            data: data,
            sourceURL: URL(string: "http://github.com/espressif/esptool/tool.tar.gz")!
        )
        #expect(throws: FlashingToolError.self) {
            try insecure.validate()
        }

        let oversized = FlashingToolDescriptor(
            identifier: insecure.identifier,
            displayName: insecure.displayName,
            version: insecure.version,
            architecture: insecure.architecture,
            archiveFileName: insecure.archiveFileName,
            sourceURL: URL(string: "https://github.com/espressif/esptool/tool.tar.gz")!,
            sha256: insecure.sha256,
            size: FlashingToolDescriptor.maximumArchiveSize + 1,
            payload: insecure.payload
        )
        #expect(throws: FlashingToolError.self) {
            try oversized.validate()
        }
    }

    @Test
    func flashingToolInspectionDistinguishesMissingReadyAndInvalidCache() async throws {
        let data = Data("fixture-tool".utf8)
        let descriptor = makeFlashingToolDescriptor(data: data)
        let root = temporaryTestDirectory("FlashingToolInspect")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = FlashingToolManager(descriptor: descriptor, cacheDirectory: root)

        #expect(await manager.inspect().phase == .missing)

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let archiveURL = await manager.archiveURL
        try data.write(to: archiveURL)
        #expect(await manager.inspect().phase == .archiveReady)

        try Data("tampered!!!!".utf8).write(to: archiveURL)
        #expect(await manager.inspect().phase == .invalid)
    }

    @Test
    func flashingToolDownloadVerifiesAndAtomicallyReplacesInvalidCache() async throws {
        let data = Data("verified-fixture-tool".utf8)
        let descriptor = makeFlashingToolDescriptor(data: data)
        let root = temporaryTestDirectory("FlashingToolDownload")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let existing = root.appendingPathComponent(descriptor.archiveFileName)
        try Data("old-invalid-cache".utf8).write(to: existing)
        let response = FlashingToolDownloadResponse(
            statusCode: 200,
            finalURL: URL(string: "https://release-assets.githubusercontent.com/espressif/tool.tar.gz")!,
            expectedContentLength: Int64(data.count),
            mimeType: "application/octet-stream"
        )
        let manager = FlashingToolManager(
            descriptor: descriptor,
            cacheDirectory: root,
            transport: MockFlashingToolDownloader(data: data, response: response)
        )

        let snapshot = try await manager.downloadAndVerify()
        let permissions = try FileManager.default.attributesOfItem(atPath: existing.path)[.posixPermissions] as? NSNumber

        #expect(snapshot.phase == .archiveReady)
        #expect(try Data(contentsOf: existing) == data)
        #expect(permissions?.intValue == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.contains(".partial-") }.isEmpty)
    }

    @Test
    func flashingToolDownloadRejectsUnsafeResponseWithoutReplacingCache() async throws {
        let data = Data("verified-fixture-tool".utf8)
        let descriptor = makeFlashingToolDescriptor(data: data)
        let root = temporaryTestDirectory("FlashingToolUnsafeResponse")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let existing = root.appendingPathComponent(descriptor.archiveFileName)
        let previous = Data("keep-this-cache".utf8)
        try previous.write(to: existing)
        let response = FlashingToolDownloadResponse(
            statusCode: 200,
            finalURL: URL(string: "http://release-assets.githubusercontent.com/espressif/tool.tar.gz")!,
            expectedContentLength: Int64(data.count),
            mimeType: "application/octet-stream"
        )
        let manager = FlashingToolManager(
            descriptor: descriptor,
            cacheDirectory: root,
            transport: MockFlashingToolDownloader(data: data, response: response)
        )

        do {
            _ = try await manager.downloadAndVerify()
            Issue.record("Expected insecure final URL to be rejected")
        } catch let error as FlashingToolError {
            #expect(error.localizedDescription.contains("HTTPS"))
        }
        #expect(try Data(contentsOf: existing) == previous)
    }

    @Test
    func flashingToolDownloadRejectsStatusTypeSizeAndDigestMismatches() async throws {
        let data = Data("verified-fixture-tool".utf8)
        let descriptor = makeFlashingToolDescriptor(data: data)
        let secureFinalURL = URL(string: "https://release-assets.githubusercontent.com/espressif/tool.tar.gz")!
        let responses = [
            FlashingToolDownloadResponse(
                statusCode: 503,
                finalURL: secureFinalURL,
                expectedContentLength: Int64(data.count),
                mimeType: "application/octet-stream"
            ),
            FlashingToolDownloadResponse(
                statusCode: 200,
                finalURL: secureFinalURL,
                expectedContentLength: Int64(data.count),
                mimeType: "text/html"
            ),
            FlashingToolDownloadResponse(
                statusCode: 200,
                finalURL: secureFinalURL,
                expectedContentLength: Int64(data.count + 1),
                mimeType: "application/octet-stream"
            ),
        ]

        for (index, response) in responses.enumerated() {
            let root = temporaryTestDirectory("FlashingToolResponse-\(index)")
            defer { try? FileManager.default.removeItem(at: root) }
            let manager = FlashingToolManager(
                descriptor: descriptor,
                cacheDirectory: root,
                transport: MockFlashingToolDownloader(data: data, response: response)
            )
            do {
                _ = try await manager.downloadAndVerify()
                Issue.record("Expected response \(index) to be rejected")
            } catch is FlashingToolError {
                // Expected.
            }
        }

        let wrongData = Data(repeating: 0x78, count: data.count)
        let digestRoot = temporaryTestDirectory("FlashingToolDigest")
        defer { try? FileManager.default.removeItem(at: digestRoot) }
        let digestManager = FlashingToolManager(
            descriptor: descriptor,
            cacheDirectory: digestRoot,
            transport: MockFlashingToolDownloader(
                data: wrongData,
                response: FlashingToolDownloadResponse(
                    statusCode: 200,
                    finalURL: secureFinalURL,
                    expectedContentLength: Int64(data.count),
                    mimeType: "application/octet-stream"
                )
            )
        )
        do {
            _ = try await digestManager.downloadAndVerify()
            Issue.record("Expected SHA-256 mismatch to be rejected")
        } catch let error as FlashingToolError {
            #expect(error.localizedDescription.contains("SHA-256"))
        }
    }

    @Test
    func flashingToolArchiveListingRejectsTraversalDuplicatesAndLinks() throws {
        let expected = ["fixture/", "fixture/esptool"]
        try SystemTarFlashingToolExtractor.validateArchiveListing(
            names: "fixture/\nfixture/esptool\n",
            verbose: "drwx------ owner group 0 Jan 1 00:00 fixture/\n-rwx------ owner group 12 Jan 1 00:00 fixture/esptool\n",
            expectedEntries: expected
        )

        #expect(throws: FlashingToolError.self) {
            try SystemTarFlashingToolExtractor.validateArchiveListing(
                names: "fixture/\n../escape\n",
                verbose: "drwx------ fixture/\n-rwx------ ../escape\n",
                expectedEntries: expected
            )
        }
        #expect(throws: FlashingToolError.self) {
            try SystemTarFlashingToolExtractor.validateArchiveListing(
                names: "fixture/\nfixture/esptool\nfixture/esptool\n",
                verbose: "drwx------ fixture/\n-rwx------ fixture/esptool\n-rwx------ fixture/esptool\n",
                expectedEntries: expected
            )
        }
        #expect(throws: FlashingToolError.self) {
            try SystemTarFlashingToolExtractor.validateArchiveListing(
                names: "fixture/\nfixture/esptool\n",
                verbose: "drwx------ fixture/\nlrwx------ fixture/esptool -> outside\n",
                expectedEntries: expected
            )
        }
    }

    @Test
    func flashingToolPreparationValidatesPayloadAndUsesPrivateModes() async throws {
        let data = Data("prepared-fixture-tool".utf8)
        let descriptor = makeFlashingToolDescriptor(data: data)
        let root = temporaryTestDirectory("FlashingToolPrepare")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try data.write(to: root.appendingPathComponent(descriptor.archiveFileName))
        let manager = FlashingToolManager(
            descriptor: descriptor,
            cacheDirectory: root,
            extractor: MockFlashingToolExtractor(data: data, behavior: .valid),
            executableValidator: MockFlashingToolExecutableValidator(),
            versionChecker: MockFlashingToolVersionChecker(reportedVersion: descriptor.version)
        )

        #expect(await manager.inspect().phase == .archiveReady)
        let snapshot = try await manager.prepareAndVerify()
        let prepared = await manager.preparedDirectoryURL
        let executable = await manager.executableURL
        let directoryMode = try FileManager.default.attributesOfItem(atPath: prepared.path)[.posixPermissions] as? NSNumber
        let executableMode = try FileManager.default.attributesOfItem(atPath: executable.path)[.posixPermissions] as? NSNumber

        #expect(snapshot.phase == .ready)
        #expect(snapshot.executableURL == executable)
        #expect(directoryMode?.intValue == 0o700)
        #expect(executableMode?.intValue == 0o700)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.contains(".partial-") && !$0.contains(".backup-") })
    }

    @Test
    func flashingToolPreparationRejectsExtraSymlinkAndWrongVersionWithoutReplacingReadyTool() async throws {
        let data = Data("prepared-fixture-tool".utf8)
        let descriptor = makeFlashingToolDescriptor(data: data)
        let root = temporaryTestDirectory("FlashingToolPrepareReject")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try data.write(to: root.appendingPathComponent(descriptor.archiveFileName))
        let validManager = FlashingToolManager(
            descriptor: descriptor,
            cacheDirectory: root,
            extractor: MockFlashingToolExtractor(data: data, behavior: .valid),
            executableValidator: MockFlashingToolExecutableValidator(),
            versionChecker: MockFlashingToolVersionChecker(reportedVersion: descriptor.version)
        )
        _ = try await validManager.prepareAndVerify()
        let preparedExecutable = await validManager.executableURL
        let original = try Data(contentsOf: preparedExecutable)

        for behavior in [MockFlashingToolExtractor.Behavior.extraFile, .symbolicLink] {
            let manager = FlashingToolManager(
                descriptor: descriptor,
                cacheDirectory: root,
                extractor: MockFlashingToolExtractor(data: data, behavior: behavior),
                executableValidator: MockFlashingToolExecutableValidator(),
                versionChecker: MockFlashingToolVersionChecker(reportedVersion: descriptor.version)
            )
            await #expect(throws: FlashingToolError.self) {
                _ = try await manager.prepareAndVerify()
            }
            #expect(try Data(contentsOf: preparedExecutable) == original)
        }

        let wrongVersionManager = FlashingToolManager(
            descriptor: descriptor,
            cacheDirectory: root,
            extractor: MockFlashingToolExtractor(data: data, behavior: .valid),
            executableValidator: MockFlashingToolExecutableValidator(),
            versionChecker: MockFlashingToolVersionChecker(reportedVersion: "0.0.0")
        )
        await #expect(throws: FlashingToolError.self) {
            _ = try await wrongVersionManager.prepareAndVerify()
        }
        #expect(try Data(contentsOf: preparedExecutable) == original)
        #expect(await validManager.inspect().phase == .ready)
    }

    @Test
    func flashingToolRemovalDeletesOnlyPinnedArchiveAndPreparedDirectory() async throws {
        let data = Data("fixture-tool".utf8)
        let descriptor = makeFlashingToolDescriptor(data: data)
        let root = temporaryTestDirectory("FlashingToolRemove")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let archive = root.appendingPathComponent(descriptor.archiveFileName)
        let prepared = root.appendingPathComponent("Prepared.noindex", isDirectory: true)
        let unrelated = root.appendingPathComponent("keep.txt")
        try data.write(to: archive)
        try FileManager.default.createDirectory(at: prepared, withIntermediateDirectories: false)
        try data.write(to: prepared.appendingPathComponent("esptool"))
        try Data("keep".utf8).write(to: unrelated)
        let manager = FlashingToolManager(descriptor: descriptor, cacheDirectory: root)

        let snapshot = try await manager.removeCachedArchive()

        #expect(snapshot.phase == .missing)
        #expect(!FileManager.default.fileExists(atPath: archive.path))
        #expect(!FileManager.default.fileExists(atPath: prepared.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
    }

    @Test
    func deviceInspectionParserAcceptsOnlyExpectedUnsecuredEightMiBESP32S3() throws {
        let inspection = try DeviceInspectionOutputParser.parse(
            securityOutput: deviceSecurityFixture(),
            flashOutput: deviceFlashFixture(),
            macOutput: deviceMACFixture(),
            descriptor: .current,
            inspectedAt: "2026-08-15T00:00:00Z"
        )

        #expect(inspection.chip == "ESP32-S3")
        #expect(inspection.flashSizeBytes == 8 * 1024 * 1024)
        #expect(!inspection.secureBootEnabled)
        #expect(!inspection.flashEncryptionEnabled)
        #expect(inspection.deviceFingerprint.count == 64)
        #expect(!inspection.deviceFingerprint.contains("02:00:00"))

        let qfnInspection = try DeviceInspectionOutputParser.parse(
            securityOutput: deviceSecurityFixture().replacingOccurrences(
                of: "ESP32-S3-PICO-1 (LGA56)",
                with: "ESP32-S3 (QFN56)"
            ),
            flashOutput: deviceFlashFixture(),
            macOutput: deviceMACFixture(),
            descriptor: .current,
            inspectedAt: "2026-08-15T00:00:00Z"
        )
        #expect(qfnInspection.chip == "ESP32-S3")

        #expect(throws: DeviceBackupError.self) {
            _ = try DeviceInspectionOutputParser.parse(
                securityOutput: deviceSecurityFixture().replacingOccurrences(
                    of: "Secure Boot: Disabled",
                    with: "Secure Boot: Enabled"
                ),
                flashOutput: deviceFlashFixture(),
                macOutput: deviceMACFixture(),
                descriptor: .current,
                inspectedAt: "2026-08-15T00:00:00Z"
            )
        }
        #expect(throws: DeviceBackupError.self) {
            _ = try DeviceInspectionOutputParser.parse(
                securityOutput: deviceSecurityFixture(),
                flashOutput: deviceFlashFixture().replacingOccurrences(of: "8MB", with: "4MB"),
                macOutput: deviceMACFixture(),
                descriptor: .current,
                inspectedAt: "2026-08-15T00:00:00Z"
            )
        }
        #expect(throws: DeviceBackupError.self) {
            _ = try DeviceInspectionOutputParser.parse(
                securityOutput: deviceSecurityFixture().replacingOccurrences(of: "ESP32-S3", with: "ESP32-C3"),
                flashOutput: deviceFlashFixture(),
                macOutput: deviceMACFixture(),
                descriptor: .current,
                inspectedAt: "2026-08-15T00:00:00Z"
            )
        }
        #expect(throws: DeviceBackupError.self) {
            _ = try DeviceInspectionOutputParser.parse(
                securityOutput: deviceSecurityFixture().replacingOccurrences(
                    of: "Chip type:          ESP32-S3-PICO-1 (LGA56) (revision v0.2)",
                    with: "Chip type:          ESP32-S3 in Secure Download Mode"
                ),
                flashOutput: deviceFlashFixture(),
                macOutput: deviceMACFixture(),
                descriptor: .current,
                inspectedAt: "2026-08-15T00:00:00Z"
            )
        }
    }

    @Test
    func deviceInspectionRejectsMissingMultipleAndNonStickUSBInputs() async throws {
        let executable = URL(fileURLWithPath: "/fixture/esptool")
        let runner = MockDeviceToolRunner()

        let missing = DeviceBackupManager(
            backupRoot: temporaryTestDirectory("DeviceMissing"),
            deviceDetector: FixedUSBDeviceDetector(candidates: []),
            runner: runner
        )
        await #expect(throws: DeviceBackupError.self) {
            _ = try await missing.inspect(executableURL: executable)
        }

        let candidate = fixtureUSBDeviceCandidate()
        let multiple = DeviceBackupManager(
            backupRoot: temporaryTestDirectory("DeviceMultiple"),
            deviceDetector: FixedUSBDeviceDetector(candidates: [candidate, candidate]),
            runner: runner
        )
        await #expect(throws: DeviceBackupError.self) {
            _ = try await multiple.inspect(executableURL: executable)
        }

        let wrong = USBDeviceCandidate(
            portPath: "/dev/cu.usbmodem99901",
            serialNumber: nil,
            vendorID: 0x1234,
            productID: 0x5678
        )
        let unsupported = DeviceBackupManager(
            backupRoot: temporaryTestDirectory("DeviceWrongUSB"),
            deviceDetector: FixedUSBDeviceDetector(candidates: [wrong]),
            runner: runner
        )
        await #expect(throws: DeviceBackupError.self) {
            _ = try await unsupported.inspect(executableURL: executable)
        }
        #expect(runner.recordedArguments().isEmpty)
    }

    @Test
    func deviceInspectionRejectsSymbolicLinkBackupRootBeforeLaunchingTool() async throws {
        let parent = temporaryTestDirectory("DeviceSymlinkRoot")
        defer { try? FileManager.default.removeItem(at: parent) }
        let target = parent.appendingPathComponent("outside", isDirectory: true)
        let backupRoot = parent.appendingPathComponent("FirmwareBackups.noindex", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: backupRoot, withDestinationURL: target)
        let runner = MockDeviceToolRunner()
        let manager = DeviceBackupManager(
            backupRoot: backupRoot,
            deviceDetector: FixedUSBDeviceDetector(candidates: [fixtureUSBDeviceCandidate()]),
            runner: runner
        )

        await #expect(throws: DeviceBackupError.self) {
            _ = try await manager.inspect(executableURL: URL(fileURLWithPath: "/fixture/esptool"))
        }
        #expect(runner.recordedArguments().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
    }

    @Test
    func deviceBackupUsesOnlyReadCommandsAndKeepsPrivateDoubleVerifiedImage() async throws {
        let root = temporaryTestDirectory("DeviceBackupSuccess")
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = MockDeviceToolRunner()
        let manager = DeviceBackupManager(
            backupRoot: root,
            deviceDetector: FixedUSBDeviceDetector(candidates: [fixtureUSBDeviceCandidate()]),
            runner: runner
        )
        let expected = try fixtureDeviceInspection()

        let receipt = try await manager.createBackup(
            expectedInspection: expected,
            executableURL: URL(fileURLWithPath: "/fixture/esptool")
        )

        let arguments = runner.recordedArguments()
        #expect(arguments.count == 5)
        #expect(arguments.compactMap(deviceSubcommand) == [
            "get-security-info", "flash-id", "read-mac", "read-flash", "read-flash",
        ])
        #expect(arguments.allSatisfy { $0.contains("--no-stub") })
        #expect(arguments.allSatisfy { !$0.contains("write-flash") && !$0.contains("erase-flash") })
        #expect(arguments[3].contains("0x800000"))
        #expect(arguments[4].contains("watchdog-reset"))

        let imageAttributes = try FileManager.default.attributesOfItem(atPath: receipt.flashImageURL.path)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: receipt.backupDirectory.path)
        let receiptAttributes = try FileManager.default.attributesOfItem(atPath: receipt.receiptURL.path)
        #expect((imageAttributes[.size] as? NSNumber)?.uint64Value == 8 * 1024 * 1024)
        #expect((imageAttributes[.posixPermissions] as? NSNumber)?.uint16Value == 0o600)
        #expect((receiptAttributes[.posixPermissions] as? NSNumber)?.uint16Value == 0o600)
        #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.uint16Value == 0o700)
        #expect(try RuntimePayloadDigest.sha256(of: receipt.flashImageURL) == receipt.flashSHA256)
        let names = try FileManager.default.contentsOfDirectory(atPath: receipt.backupDirectory.path).sorted()
        #expect(names == ["flash-8MiB.bin", "receipt-v1.json"])
        let receiptText = try String(contentsOf: receipt.receiptURL, encoding: .utf8)
        #expect(!receiptText.contains("34:85:18"))
        #expect(receiptText.contains("two-complete-reads-sha256-match"))
    }

    @Test
    func deviceBackupRejectsChangedIdentityAndMismatchedSecondReadWithoutPartials() async throws {
        let changedRoot = temporaryTestDirectory("DeviceBackupChanged")
        defer { try? FileManager.default.removeItem(at: changedRoot) }
        let changedRunner = MockDeviceToolRunner(macAddresses: ["02:00:00:11:22:33"])
        let changedManager = DeviceBackupManager(
            backupRoot: changedRoot,
            deviceDetector: FixedUSBDeviceDetector(candidates: [fixtureUSBDeviceCandidate()]),
            runner: changedRunner
        )
        await #expect(throws: DeviceBackupError.self) {
            _ = try await changedManager.createBackup(
                expectedInspection: fixtureDeviceInspection(),
                executableURL: URL(fileURLWithPath: "/fixture/esptool")
            )
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: changedRoot.path).isEmpty)

        let mismatchRoot = temporaryTestDirectory("DeviceBackupMismatch")
        defer { try? FileManager.default.removeItem(at: mismatchRoot) }
        let mismatchRunner = MockDeviceToolRunner(mismatchSecondRead: true)
        let mismatchManager = DeviceBackupManager(
            backupRoot: mismatchRoot,
            deviceDetector: FixedUSBDeviceDetector(candidates: [fixtureUSBDeviceCandidate()]),
            runner: mismatchRunner
        )
        await #expect(throws: DeviceBackupError.self) {
            _ = try await mismatchManager.createBackup(
                expectedInspection: fixtureDeviceInspection(),
                executableURL: URL(fileURLWithPath: "/fixture/esptool")
            )
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: mismatchRoot.path).isEmpty)
    }

    @Test
    func deviceFlashPlanPinsSectorSafeRegionsAndRejectsNVSOverlap() throws {
        let root = temporaryTestDirectory("DeviceFlashPlan")
        defer { try? FileManager.default.removeItem(at: root) }
        try makeFirmwarePayload(at: root)
        let manifestData = try Data(contentsOf: root.appendingPathComponent("manifest-v1.json"))
        let manifest = try JSONDecoder().decode(FirmwarePayloadManifest.self, from: manifestData)
        let plan = try DeviceFlashPlan(manifest: manifest)

        #expect(plan.regions.map(\.offset) == [0x0, 0x8000, 0x10000])
        #expect(plan.regions.allSatisfy { $0.eraseStart.isMultiple(of: 0x1000) })
        #expect(plan.regions.allSatisfy { $0.eraseEndExclusive.isMultiple(of: 0x1000) })
        #expect(plan.regions.allSatisfy {
            $0.eraseEndExclusive <= plan.preservedNVS.start
                || $0.eraseStart >= plan.preservedNVS.endExclusive
        })

        let overlappingFiles = manifest.files.map { file in
            file.path == "partition-table.bin"
                ? FirmwarePayloadFile(
                    mode: file.mode,
                    offset: file.offset,
                    path: file.path,
                    sha256: file.sha256,
                    size: 0x1001
                )
                : file
        }
        let overlappingManifest = FirmwarePayloadManifest(
            board: manifest.board,
            files: overlappingFiles,
            flash: manifest.flash,
            payloadVersion: manifest.payloadVersion,
            preservedRanges: manifest.preservedRanges,
            schemaVersion: manifest.schemaVersion,
            source: manifest.source,
            target: manifest.target
        )
        #expect(throws: DeviceFlashError.nvsOverlap) {
            _ = try DeviceFlashPlan(manifest: overlappingManifest)
        }
        #expect(throws: DeviceFlashError.commandNotAllowed) {
            try DeviceFlashCommandPolicy.validate(
                [
                    "--chip", "esp32s3", "--before", "no-reset", "--after", "no-reset",
                    "--no-stub", "write-flash", "--force", "0x0", "/fixture/image.bin",
                ],
                expectedCommand: "write-flash"
            )
        }
    }

    @Test
    func deviceFlashLocalReadinessValidatesPayloadAndPrivateBackupWithoutToolCalls() async throws {
        let fixture = try makeDeviceFlashFixture("DeviceFlashReady")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let snapshot = await fixture.manager.inspectLocalReadiness()

        #expect(snapshot.phase == .ready)
        #expect(snapshot.payloadVersion == "0.2.0-m4.4a-test")
        #expect(snapshot.backupReady)
        #expect(fixture.runner.recordedArguments().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.transactionRoot.path))
    }

    @Test
    func candidateWriteUsesOneFixedWriteAndPersistsUnverifiedJournal() async throws {
        let fixture = try makeDeviceFlashFixture("DeviceFlashWrite")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let snapshot = try await fixture.manager.writeCandidate(executableURL: fixture.executableURL)

        #expect(snapshot.phase == .writeUnverified)
        let arguments = fixture.runner.recordedArguments()
        #expect(arguments.compactMap(deviceFlashSubcommand) == [
            "get-security-info", "flash-id", "read-mac", "read-flash", "write-flash",
        ])
        let write = try #require(arguments.last)
        #expect(write.filter { $0.hasPrefix("0x") } == ["0x0", "0x8000", "0x10000"])
        #expect(write.contains("no-reset"))
        #expect(DeviceFlashCommandPolicy.forbiddenArguments.allSatisfy { !write.contains($0) })
        let journal = fixture.transactionRoot.appendingPathComponent("latest-v1.json")
        let prewriteNVS = fixture.transactionRoot.appendingPathComponent("prewrite-nvs-v1.bin")
        let rootMode = try #require(
            FileManager.default.attributesOfItem(atPath: fixture.transactionRoot.path)[.posixPermissions]
                as? NSNumber
        ).uint16Value
        let journalMode = try #require(
            FileManager.default.attributesOfItem(atPath: journal.path)[.posixPermissions] as? NSNumber
        ).uint16Value
        let prewriteNVSMode = try #require(
            FileManager.default.attributesOfItem(atPath: prewriteNVS.path)[.posixPermissions] as? NSNumber
        ).uint16Value
        #expect(rootMode == 0o700)
        #expect(journalMode == 0o600)
        #expect(prewriteNVSMode == 0o600)
        #expect(try Data(contentsOf: prewriteNVS).count == 0x6000)
        #expect(try String(contentsOf: journal, encoding: .utf8).contains("write-unverified"))
        #expect(try String(contentsOf: journal, encoding: .utf8).contains("prewrite_nvs_sha256"))
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: fixture.transactionRoot.path)) == [
            "latest-v1.json", "prewrite-nvs-v1.bin",
        ])
    }

    @Test
    func candidateVerificationReadsEveryRegionAndNVSBeforeReset() async throws {
        let fixture = try makeDeviceFlashFixture("DeviceFlashVerify")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.manager.writeCandidate(executableURL: fixture.executableURL)

        let snapshot = try await fixture.manager.verifyCandidate(executableURL: fixture.executableURL)

        #expect(snapshot.phase == .verified)
        let allReads = fixture.runner.recordedArguments().filter { deviceFlashSubcommand($0) == "read-flash" }
        #expect(allReads.count == 5)
        #expect(Array(allReads.first?.suffix(3).prefix(2) ?? []) == ["0x9000", "0x6000"])
        let verificationReads = Array(allReads.suffix(4))
        #expect(verificationReads.map { Array($0.suffix(3).prefix(2)) } == [
            ["0x0", "0x12"], ["0x8000", "0x12"], ["0x10000", "0x13"], ["0x9000", "0x6000"],
        ])
        #expect(allReads.dropLast().allSatisfy { $0.contains("no-reset") && !$0.contains("watchdog-reset") })
        #expect(allReads.last?.contains("watchdog-reset") == true)
        #expect(fixture.runner.recordedArguments().allSatisfy { arguments in
            DeviceFlashCommandPolicy.forbiddenArguments.allSatisfy { forbidden in
                !arguments.contains(forbidden)
            }
        })
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: fixture.transactionRoot.path)) == [
            "latest-v1.json", "prewrite-nvs-v1.bin",
        ])
    }

    @Test
    func candidateVerificationUsesImmediatePrewriteNVSSnapshotInsteadOfOlderBackup() async throws {
        let fixture = try makeDeviceFlashFixture("DeviceFlashFreshNVS")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.runner.corruptMemory(at: 0x9000)

        _ = try await fixture.manager.writeCandidate(executableURL: fixture.executableURL)
        let snapshot = try await fixture.manager.verifyCandidate(executableURL: fixture.executableURL)

        #expect(snapshot.phase == .verified)
        let prewriteNVS = fixture.transactionRoot.appendingPathComponent("prewrite-nvs-v1.bin")
        #expect(try Data(contentsOf: prewriteNVS).first == 0xa5)
    }

    @Test
    func missingPrewriteNVSSnapshotRequiresRecoveryBeforeAnyVerificationToolCall() async throws {
        let fixture = try makeDeviceFlashFixture("DeviceFlashMissingFreshNVS")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.manager.writeCandidate(executableURL: fixture.executableURL)
        let prewriteNVS = fixture.transactionRoot.appendingPathComponent("prewrite-nvs-v1.bin")
        try FileManager.default.removeItem(at: prewriteNVS)
        let callCount = fixture.runner.recordedArguments().count

        #expect(await fixture.manager.inspectLocalReadiness().phase == .recoveryRequired)
        await #expect(throws: DeviceFlashError.invalidPrewriteNVSSnapshot) {
            _ = try await fixture.manager.verifyCandidate(executableURL: fixture.executableURL)
        }
        #expect(fixture.runner.recordedArguments().count == callCount)
    }

    @Test
    func candidateMismatchBecomesRecoveryRequiredWithoutAutomaticWrite() async throws {
        let fixture = try makeDeviceFlashFixture("DeviceFlashMismatch")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.manager.writeCandidate(executableURL: fixture.executableURL)
        fixture.runner.corruptMemory(at: 0)

        await #expect(throws: DeviceFlashError.candidateMismatch) {
            _ = try await fixture.manager.verifyCandidate(executableURL: fixture.executableURL)
        }

        #expect(await fixture.manager.inspectLocalReadiness().phase == .recoveryRequired)
        #expect(fixture.runner.recordedArguments().filter { deviceFlashSubcommand($0) == "write-flash" }.count == 1)
    }

    @Test
    func fullBackupRestoreRequiresIndependentCompleteReadback() async throws {
        let fixture = try makeDeviceFlashFixture("DeviceFlashRestore")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.manager.writeCandidate(executableURL: fixture.executableURL)
        fixture.runner.corruptMemory(at: 0x10000)

        let restoredPending = try await fixture.manager.restoreBackup(executableURL: fixture.executableURL)
        #expect(restoredPending.phase == .restoreUnverified)
        let write = try #require(
            fixture.runner.recordedArguments().last { deviceFlashSubcommand($0) == "write-flash" }
        )
        #expect(write.filter { $0.hasPrefix("0x") } == ["0x0"])
        let writeSource = try #require(write.last)
        #expect(
            URL(fileURLWithPath: writeSource).resolvingSymlinksInPath()
                == fixture.backupImage.resolvingSymlinksInPath()
        )

        let restored = try await fixture.manager.verifyRestore(executableURL: fixture.executableURL)
        #expect(restored.phase == .restored)
        let finalRead = try #require(
            fixture.runner.recordedArguments().last { deviceFlashSubcommand($0) == "read-flash" }
        )
        #expect(Array(finalRead.suffix(3).prefix(2)) == ["0x0", "0x800000"])
        #expect(finalRead.contains("watchdog-reset"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.transactionRoot.path) == ["latest-v1.json"])
    }

    @Test
    func runtimePendingSendBlocksBeforeAnyDeviceToolCommand() async throws {
        let fixture = try makeDeviceFlashFixture("DeviceFlashBusy", recordingStatus: "pending_send")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        await #expect(throws: DeviceFlashError.runtimeBusy) {
            _ = try await fixture.manager.writeCandidate(executableURL: fixture.executableURL)
        }
        #expect(fixture.runner.recordedArguments().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.transactionRoot.path))
    }
}

private struct FixedUSBDeviceDetector: USBDeviceDetecting {
    let candidates: [USBDeviceCandidate]

    func detectAll() async -> [USBDeviceCandidate] {
        candidates
    }
}

private final class MockDeviceToolRunner: DeviceToolRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var invocations: [[String]] = []
    private var macAddresses: [String]
    private var readCount = 0
    private let mismatchSecondRead: Bool

    init(
        macAddresses: [String] = ["02:00:00:aa:bb:cc"],
        mismatchSecondRead: Bool = false
    ) {
        self.macAddresses = macAddresses
        self.mismatchSecondRead = mismatchSecondRead
    }

    func run(
        executableURL: URL,
        arguments: [String],
        workingDirectory: URL,
        timeout: TimeInterval
    ) throws -> DeviceToolResult {
        lock.lock()
        invocations.append(arguments)
        let command = deviceSubcommand(arguments)
        var selectedMAC = macAddresses.first ?? "02:00:00:aa:bb:cc"
        if command == "read-mac", macAddresses.count > 1 {
            selectedMAC = macAddresses.removeFirst()
        }
        if command == "read-flash" { readCount += 1 }
        let selectedReadCount = readCount
        lock.unlock()

        switch command {
        case "get-security-info":
            return DeviceToolResult(standardOutput: deviceSecurityFixture(), standardError: "")
        case "flash-id":
            return DeviceToolResult(standardOutput: deviceFlashFixture(), standardError: "")
        case "read-mac":
            return DeviceToolResult(standardOutput: deviceMACFixture(selectedMAC), standardError: "")
        case "read-flash":
            let outputURL = URL(fileURLWithPath: try #require(arguments.last))
            let byte: UInt8 = mismatchSecondRead && selectedReadCount == 2 ? 0x5b : 0x5a
            let handle = try FileHandle(forWritingTo: outputURL)
            try handle.truncate(atOffset: 0)
            let chunk = Data(repeating: byte, count: 64 * 1024)
            for _ in 0..<128 {
                try handle.write(contentsOf: chunk)
            }
            try handle.close()
            return DeviceToolResult(
                standardOutput: "Read 8388608 bytes from 0x00000000 in 1.0 seconds.\n",
                standardError: ""
            )
        default:
            throw DeviceBackupError.commandNotAllowed
        }
    }

    func recordedArguments() -> [[String]] {
        lock.withLock { invocations }
    }
}

private final class MockDeviceFlashRunner: DeviceToolRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var invocations: [[String]] = []
    private var flash: Data
    private var macAddress = "02:00:00:aa:bb:cc"

    init(flash: Data) {
        self.flash = flash
    }

    func run(
        executableURL: URL,
        arguments: [String],
        workingDirectory: URL,
        timeout: TimeInterval
    ) throws -> DeviceToolResult {
        lock.lock()
        defer { lock.unlock() }
        invocations.append(arguments)
        switch deviceFlashSubcommand(arguments) {
        case "get-security-info":
            return DeviceToolResult(standardOutput: deviceSecurityFixture(), standardError: "")
        case "flash-id":
            return DeviceToolResult(standardOutput: deviceFlashFixture(), standardError: "")
        case "read-mac":
            return DeviceToolResult(standardOutput: deviceMACFixture(macAddress), standardError: "")
        case "write-flash":
            let commandIndex = try #require(arguments.firstIndex(of: "write-flash"))
            var index = commandIndex + 1
            var wroteRegion = false
            while index + 1 < arguments.count {
                guard arguments[index].hasPrefix("0x"),
                      let offset = parseHex(arguments[index]) else {
                    index += 1
                    continue
                }
                let source = URL(fileURLWithPath: arguments[index + 1])
                let data = try Data(contentsOf: source)
                let start = Int(offset)
                guard start >= 0, start + data.count <= flash.count else {
                    throw DeviceFlashError.commandNotAllowed
                }
                flash.replaceSubrange(start..<(start + data.count), with: data)
                wroteRegion = true
                index += 2
            }
            guard wroteRegion else { throw DeviceFlashError.commandNotAllowed }
            return DeviceToolResult(
                standardOutput: "Wrote fixed ranges.\nHash of data verified.\n",
                standardError: ""
            )
        case "read-flash":
            let tail = Array(arguments.suffix(3))
            guard tail.count == 3,
                  let offset = parseHex(tail[0]),
                  let size = parseHex(tail[1]) else {
                throw DeviceFlashError.commandNotAllowed
            }
            let start = Int(offset)
            let count = Int(size)
            guard start >= 0, count >= 0, start + count <= flash.count else {
                throw DeviceFlashError.commandNotAllowed
            }
            let output = URL(fileURLWithPath: tail[2])
            let handle = try FileHandle(forWritingTo: output)
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: flash.subdata(in: start..<(start + count)))
            try handle.close()
            return DeviceToolResult(
                standardOutput: "Read \(count) bytes from \(tail[0]).\n",
                standardError: ""
            )
        default:
            throw DeviceFlashError.commandNotAllowed
        }
    }

    func recordedArguments() -> [[String]] {
        lock.withLock { invocations }
    }

    func corruptMemory(at offset: Int) {
        lock.withLock {
            guard flash.indices.contains(offset) else { return }
            flash[offset] ^= 0xff
        }
    }

    private func parseHex(_ value: String) -> UInt64? {
        guard value.hasPrefix("0x") else { return nil }
        return UInt64(value.dropFirst(2), radix: 16)
    }
}

private struct DeviceFlashFixture {
    let root: URL
    let transactionRoot: URL
    let backupImage: URL
    let executableURL: URL
    let runner: MockDeviceFlashRunner
    let manager: DeviceFlashManager
}

private func makeDeviceFlashFixture(
    _ label: String,
    recordingStatus: String? = nil
) throws -> DeviceFlashFixture {
    let root = temporaryTestDirectory(label)
    let firmwareRoot = root.appendingPathComponent("FirmwarePayload.noindex", isDirectory: true)
    let backupRoot = root.appendingPathComponent("FirmwareBackups.noindex", isDirectory: true)
    let backupDirectory = backupRoot.appendingPathComponent("20260815T000000Z-test", isDirectory: true)
    let transactionRoot = root.appendingPathComponent("FirmwareTransactions.noindex", isDirectory: true)
    let recordingFile = root.appendingPathComponent("recording-v1.json")
    try makeFirmwarePayload(at: firmwareRoot)
    try FileManager.default.createDirectory(
        at: backupDirectory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: backupRoot.path)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: backupDirectory.path)

    let flash = Data(repeating: 0x5a, count: 8 * 1024 * 1024)
    let backupImage = backupDirectory.appendingPathComponent("flash-8MiB.bin")
    try flash.write(to: backupImage)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupImage.path)
    let inspection = try fixtureDeviceInspection()
    let digest = try RuntimePayloadDigest.sha256(of: backupImage)
    let receipt: [String: Any] = [
        "schema_version": 1,
        "created_at": "2026-08-15T00:00:00Z",
        "tool": "esptool",
        "tool_version": "5.3.1",
        "chip": "ESP32-S3",
        "flash_size_bytes": 8 * 1024 * 1024,
        "flash_manufacturer_id": "ef",
        "flash_device_id": "4017",
        "secure_boot_enabled": false,
        "flash_encryption_enabled": false,
        "device_fingerprint_sha256": inspection.deviceFingerprint,
        "image": [
            "path": "flash-8MiB.bin",
            "offset": "0x0",
            "size": 8 * 1024 * 1024,
            "sha256": digest,
            "verification": "two-complete-reads-sha256-match",
        ],
    ]
    let receiptURL = backupDirectory.appendingPathComponent("receipt-v1.json")
    try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
        .write(to: receiptURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receiptURL.path)

    if let recordingStatus {
        let document: [String: Any] = ["active": false, "status": recordingStatus]
        try JSONSerialization.data(withJSONObject: document).write(to: recordingFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recordingFile.path)
    }

    let runner = MockDeviceFlashRunner(flash: flash)
    let manager = DeviceFlashManager(
        firmwareRoot: firmwareRoot,
        backupRoot: backupRoot,
        transactionRoot: transactionRoot,
        recordingFile: recordingFile,
        deviceDetector: FixedUSBDeviceDetector(candidates: [fixtureUSBDeviceCandidate()]),
        runner: runner
    )
    return DeviceFlashFixture(
        root: root,
        transactionRoot: transactionRoot,
        backupImage: backupImage,
        executableURL: URL(fileURLWithPath: "/fixture/esptool"),
        runner: runner,
        manager: manager
    )
}

private func deviceSubcommand(_ arguments: [String]) -> String? {
    arguments.first { ["get-security-info", "flash-id", "read-mac", "read-flash"].contains($0) }
}

private func deviceFlashSubcommand(_ arguments: [String]) -> String? {
    arguments.first {
        ["get-security-info", "flash-id", "read-mac", "read-flash", "write-flash"].contains($0)
    }
}

private func fixtureUSBDeviceCandidate() -> USBDeviceCandidate {
    USBDeviceCandidate(
        portPath: "/dev/cu.usbmodem31101",
        serialNumber: nil,
        vendorID: USBDeviceCandidate.esp32S3VendorID,
        productID: USBDeviceCandidate.usbSerialJTAGProductID
    )
}

private func deviceSecurityFixture() -> String {
    """
    esptool v5.3.1
    Connected to ESP32-S3 on /dev/cu.usbmodem31101:
    Chip type:          ESP32-S3-PICO-1 (LGA56) (revision v0.2)
    Security Information:
    =====================
    Flags: 0x00000000 (0b0)
    Chip ID: 9
    API Version: 0
    Secure Boot: Disabled
    Flash Encryption: Disabled
    SPI Boot Crypt Count (SPI_BOOT_CRYPT_CNT): 0x0
    """
}

private func deviceFlashFixture() -> String {
    """
    Flash Memory Information:
    =========================
    Manufacturer: ef
    Device: 4017
    Detected flash size: 8MB
    Flash type set in eFuse: quad (4 data lines)
    """
}

private func deviceMACFixture(_ mac: String = "02:00:00:aa:bb:cc") -> String {
    "MAC: \(mac)\n"
}

private func fixtureDeviceInspection() throws -> DeviceSecurityInspection {
    try DeviceInspectionOutputParser.parse(
        securityOutput: deviceSecurityFixture(),
        flashOutput: deviceFlashFixture(),
        macOutput: deviceMACFixture(),
        descriptor: .current,
        inspectedAt: "2026-08-15T00:00:00Z"
    )
}

private struct MockFlashingToolDownloader: FlashingToolDownloading {
    let data: Data
    let response: FlashingToolDownloadResponse

    func download(from sourceURL: URL, to destinationURL: URL) async throws -> FlashingToolDownloadResponse {
        try data.write(to: destinationURL)
        return response
    }
}

private struct MockFlashingToolExtractor: FlashingToolExtracting {
    enum Behavior: Sendable {
        case valid
        case extraFile
        case symbolicLink
    }

    let data: Data
    let behavior: Behavior

    func extract(
        archiveURL: URL,
        to destinationURL: URL,
        expectedEntries: [String]
    ) throws {
        let executable = destinationURL.appendingPathComponent("esptool")
        switch behavior {
        case .valid:
            try data.write(to: executable)
        case .extraFile:
            try data.write(to: executable)
            try Data("unexpected".utf8).write(to: destinationURL.appendingPathComponent("extra"))
        case .symbolicLink:
            try FileManager.default.createSymbolicLink(
                at: executable,
                withDestinationURL: URL(fileURLWithPath: "/private/tmp/outside")
            )
        }
    }
}

private struct MockFlashingToolExecutableValidator: FlashingToolExecutableValidating {
    func validate(
        executableURL: URL,
        teamIdentifier: String,
        signingIdentifier: String
    ) throws {}
}

private struct MockFlashingToolVersionChecker: FlashingToolVersionChecking {
    let reportedVersion: String

    func version(executableURL: URL, expectedVersion: String) throws -> String {
        guard reportedVersion == expectedVersion else {
            throw FlashingToolError.versionMismatch
        }
        return reportedVersion
    }
}

private func makeFlashingToolDescriptor(
    data: Data,
    sourceURL: URL = URL(string: "https://github.com/espressif/esptool/tool.tar.gz")!
) -> FlashingToolDescriptor {
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    return FlashingToolDescriptor(
        identifier: "test-esptool",
        displayName: "Test esptool",
        version: "5.3.1",
        architecture: "arm64",
        archiveFileName: "tool.tar.gz",
        sourceURL: sourceURL,
        sha256: digest,
        size: UInt64(data.count),
        payload: FlashingToolPayloadDescriptor(
            archiveRootDirectory: "fixture",
            signingTeamIdentifier: "TESTTEAM01",
            files: [
                FlashingToolPayloadFile(
                    path: "esptool",
                    size: UInt64(data.count),
                    sha256: digest,
                    executable: true,
                    signingIdentifier: "esptool"
                ),
            ]
        )
    )
}

private struct RuntimeInstallFixture {
    let root: URL
    let payload: URL
    let layout: RuntimeInstallLayout
    let privateConfiguration: URL
}

private func temporaryTestDirectory(_ label: String) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("VibeStick-\(label)-\(UUID().uuidString)", isDirectory: true)
}

private func writeTestFile(_ contents: String, to url: URL, mode: UInt16 = 0o644) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data(contents.utf8).write(to: url)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: mode)],
        ofItemAtPath: url.path
    )
}

private func makeRuntimePayload(
    at root: URL,
    replaceExisting: Bool = false
) throws {
    if replaceExisting, FileManager.default.fileExists(atPath: root.path) {
        try FileManager.default.removeItem(at: root)
    }
    let files: [(String, String, UInt16)] = [
        ("Components.noindex/VibeStick Bridge.app/Contents/MacOS/VibeStickBridge", "new-bridge", 0o755),
        ("Components.noindex/VibeStick HUD.app/Contents/MacOS/VibeStickHUD", "new-hud", 0o755),
        ("Components.noindex/VibeStick Paste.app/Contents/MacOS/VibeStickPaste", "new-paste", 0o755),
        ("Components.noindex/VibeStick Paste.app/Contents/Resources/VibeStickPaste.build", "paste-build-1\n", 0o644),
    ]
    for (relativePath, contents, mode) in files {
        try writeTestFile(contents, to: root.appendingPathComponent(relativePath), mode: mode)
    }

    let entries = try files.map { item in
        let (relativePath, _, mode) = item
        let url = root.appendingPathComponent(relativePath)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        return RuntimePayloadFile(
            path: relativePath,
            sha256: try RuntimePayloadDigest.sha256(of: url),
            size: size,
            mode: mode
        )
    }.sorted { $0.path < $1.path }
    let manifest = RuntimePayloadManifest(
        schemaVersion: RuntimePayloadManifest.currentSchemaVersion,
        payloadVersion: "test-m4.2",
        files: entries
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(manifest).write(
        to: root.appendingPathComponent(RuntimePayloadValidator.manifestName)
    )
}

private func makeFirmwarePayload(
    at root: URL,
    replaceExisting: Bool = false
) throws {
    if replaceExisting, FileManager.default.fileExists(atPath: root.path) {
        try FileManager.default.removeItem(at: root)
    }
    let contents: [String: String] = [
        "bootloader.bin": "fixture-bootloader",
        "partition-table.bin": "fixture-partitions",
        "vibe-stick.bin": "fixture-application",
    ]
    var files: [FirmwarePayloadFile] = []
    for (path, contents) in contents {
        let url = root.appendingPathComponent(path)
        try writeTestFile(contents, to: url)
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0
        files.append(
            FirmwarePayloadFile(
                mode: 0o644,
                offset: try #require(FirmwarePayloadValidator.requiredOffsets[path]),
                path: path,
                sha256: try RuntimePayloadDigest.sha256(of: url),
                size: size
            )
        )
    }
    let manifest = FirmwarePayloadManifest(
        board: "M5Stack StickS3",
        files: files.sorted { $0.offset < $1.offset },
        flash: FirmwareFlashGeometry(frequency: "80m", mode: "dio", size: 8 * 1024 * 1024),
        payloadVersion: "0.2.0-m4.4a-test",
        preservedRanges: [FirmwarePayloadValidator.preservedNVS],
        schemaVersion: FirmwarePayloadManifest.currentSchemaVersion,
        source: FirmwareSourceIdentity(digest: String(repeating: "b", count: 64), revision: String(repeating: "a", count: 40)),
        target: "esp32s3"
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(manifest).write(
        to: root.appendingPathComponent(FirmwarePayloadValidator.manifestName)
    )
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o644)],
        ofItemAtPath: root.appendingPathComponent(FirmwarePayloadValidator.manifestName).path
    )
}

private func makeRuntimeInstallFixture(_ label: String) throws -> RuntimeInstallFixture {
    let root = temporaryTestDirectory(label)
    let payload = root.appendingPathComponent("payload", isDirectory: true)
    let support = root.appendingPathComponent("home/Library/Application Support/VibeStick", isDirectory: true)
    let launchAgents = root.appendingPathComponent("home/Library/LaunchAgents", isDirectory: true)
    let layout = RuntimeInstallLayout(
        supportDirectory: support,
        launchAgentsDirectory: launchAgents
    )
    try makeRuntimePayload(at: payload)
    try writeTestFile("old-runtime", to: layout.runtimeDirectory.appendingPathComponent("bridge/version.txt"))
    try writeTestFile("old-bridge", to: layout.bridgeApp.appendingPathComponent("Contents/MacOS/VibeStickBridge"), mode: 0o755)
    try writeTestFile("old-hud", to: layout.hudApp.appendingPathComponent("Contents/MacOS/VibeStickHUD"), mode: 0o755)
    try writeTestFile("old-paste", to: layout.pasteApp.appendingPathComponent("Contents/MacOS/VibeStickPaste"), mode: 0o755)
    try writeTestFile("paste-build-1\n", to: layout.pasteApp.appendingPathComponent("Contents/Resources/VibeStickPaste.build"))
    try writeTestFile("old-bridge-plist", to: layout.bridgeLaunchAgent, mode: 0o600)
    try writeTestFile("old-hud-plist", to: layout.hudLaunchAgent, mode: 0o600)
    let privateConfiguration = support.appendingPathComponent("config-v1.json")
    try writeTestFile("do-not-touch", to: privateConfiguration, mode: 0o600)
    return RuntimeInstallFixture(
        root: root,
        payload: payload,
        layout: layout,
        privateConfiguration: privateConfiguration
    )
}

private final class RuntimeInstallEventTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    var events: [String] {
        lock.withLock { recorded }
    }

    func append(_ event: String) {
        lock.withLock { recorded.append(event) }
    }
}

private actor MockRuntimeInstallController: RuntimeInstallServiceControlling {
    private let preservePaste: Bool
    private let trace: RuntimeInstallEventTrace?
    private var events: [String] = []
    private var restoredCheckpoint: RuntimeServiceCheckpoint?

    init(preservePaste: Bool, trace: RuntimeInstallEventTrace? = nil) {
        self.preservePaste = preservePaste
        self.trace = trace
    }

    func preflight() -> RuntimeInstallPreflight {
        events.append("preflight")
        trace?.append("preflight")
        return RuntimeInstallPreflight(
            checkpoint: RuntimeServiceCheckpoint(
                bridgeWasLoaded: true,
                bridgeWasRunning: true,
                hudWasLoaded: true,
                hudWasRunning: true
            )
        )
    }

    func validateComponents(at componentsDirectory: URL) {
        events.append("validate")
        trace?.append("validate")
    }

    func revalidateBeforeMutation() -> RuntimeServiceCheckpoint {
        events.append("revalidate")
        trace?.append("revalidate")
        return RuntimeServiceCheckpoint(
            bridgeWasLoaded: true,
            bridgeWasRunning: true,
            hudWasLoaded: true,
            hudWasRunning: true
        )
    }

    func canPreservePasteIdentity(existing: URL, candidate: URL) -> Bool {
        events.append("paste")
        trace?.append("paste")
        return preservePaste
    }

    func stopManagedServices() {
        events.append("stop")
        trace?.append("stop")
    }

    func startInstalledServices() {
        events.append("start")
        trace?.append("start")
    }

    func verifyInstalledServices() {
        events.append("verify")
        trace?.append("verify")
    }

    func restoreServiceState(_ checkpoint: RuntimeServiceCheckpoint) {
        events.append("restore")
        trace?.append("restore")
        restoredCheckpoint = checkpoint
    }

    func recordedEvents() -> [String] {
        events
    }

    func didRestore(_ checkpoint: RuntimeServiceCheckpoint) -> Bool {
        restoredCheckpoint == checkpoint
    }
}

private actor MockRuntimeConfigurationBootstrapper: RuntimeConfigurationBootstrapping {
    private let trace: RuntimeInstallEventTrace?
    private let receipt: RuntimeFreshInstallConfigurationBootstrapReceipt

    init() {
        self.trace = nil
        self.receipt = .unchanged
    }

    init(trace: RuntimeInstallEventTrace) {
        self.trace = trace
        self.receipt = RuntimeFreshInstallConfigurationBootstrapReceipt(
            createdManagedConfiguration: true,
            createdBridgeCredential: true
        )
    }

    func prepareIfNeeded() -> RuntimeFreshInstallConfigurationBootstrapReceipt {
        trace?.append("bootstrap")
        return receipt
    }

    func rollback(_ receipt: RuntimeFreshInstallConfigurationBootstrapReceipt) {
        trace?.append("bootstrap-rollback")
    }
}

private actor FictionalRuntimeBootstrapCredentialVault: M4OfflineCredentialVault {
    private var items: [M4VersionedCredentialReference: Data] = [:]

    func stage(_ secret: Data, for reference: M4VersionedCredentialReference) throws {
        guard items[reference] == nil else {
            throw M4ProductionMigrationAdapterError.managedCredentialAlreadyExists
        }
        items[reference] = secret
    }

    func read(_ reference: M4VersionedCredentialReference) -> Data? {
        items[reference]
    }

    func contains(_ reference: M4VersionedCredentialReference) -> Bool {
        items[reference] != nil
    }

    func discard(_ reference: M4VersionedCredentialReference) {
        items.removeValue(forKey: reference)
    }

    func legacyAccountsRemainUntouched() -> Bool {
        true
    }
}

private actor FictionalManagedASRGenericPasswordClient: M4VersionedGenericPasswordAccess {
    private var items: [M4VersionedCredentialReference: Data]
    private(set) var readReferences: [M4VersionedCredentialReference] = []

    init(items: [M4VersionedCredentialReference: Data]) {
        self.items = items
    }

    func contains(_ reference: M4VersionedCredentialReference) -> Bool {
        items[reference] != nil
    }

    func read(_ reference: M4VersionedCredentialReference) -> Data? {
        readReferences.append(reference)
        return items[reference]
    }

    func add(_ data: Data, for reference: M4VersionedCredentialReference) throws {
        guard items[reference] == nil else {
            throw M4ProductionMigrationAdapterError.managedCredentialAlreadyExists
        }
        items[reference] = data
    }

    func delete(_ reference: M4VersionedCredentialReference) {
        items.removeValue(forKey: reference)
    }

    func value(for reference: M4VersionedCredentialReference) -> Data? {
        items[reference]
    }

    func resetReadReferences() {
        readReferences = []
    }
}

private struct MockSecretStore: SecretStoring {
    let present: Set<KeychainSecret>

    func contains(_ key: KeychainSecret) -> Bool {
        present.contains(key)
    }
}

private func m4HManagedRuntimeConfigurationFixture() -> M4ManagedRuntimeConfiguration {
    M4ManagedRuntimeConfiguration(
        schemaVersion: M4ManagedRuntimeConfiguration.currentSchemaVersion,
        credentialReferences: [
            .managed(.bridgeToken),
            .managed(.asrAPIKey),
        ],
        asr: M4ManagedASRConfiguration(
            provider: "openai-compatible",
            baseURL: "https://fictional.invalid/v1/audio/transcriptions",
            model: "fictional-m4-5h-model",
            language: "zh",
            localCommand: ""
        ),
        agentProvider: "auto",
        projectPresentation: M4ManagedProjectPresentation(
            projectName: "Fictional M4-5H Project",
            showProjectName: true
        ),
        voiceDelivery: M4ManagedVoiceDelivery(sendMode: "confirm"),
        soundEnabled: true
    )
}

private actor MockManagedCredentialPresenceChecker: M4ManagedCredentialPresenceChecking {
    private let present: Set<M4VersionedCredentialReference>
    private(set) var checkedReferences: [M4VersionedCredentialReference] = []

    init(present: Set<M4VersionedCredentialReference>) {
        self.present = present
    }

    func contains(_ reference: M4VersionedCredentialReference) -> Bool {
        checkedReferences.append(reference)
        return present.contains(reference)
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

private actor UnconfiguredSchemaTwoPairingSerialClient: DeviceSerialPairing {
    private var pairAttempts = 0

    func identify(portPath: String) -> DeviceIdentity {
        DeviceIdentity(
            deviceID: "vs-001122334455",
            model: "M5Stack StickS3",
            firmwareVersion: "0.2.0-m4.4a",
            protocolVersion: 2,
            pairingID: nil,
            pairingSchemaVersion: 2,
            wifiConfigured: false
        )
    }

    func pair(
        identity: DeviceIdentity,
        material: PairingMaterial,
        bridgeID: String,
        fallbackHost: String,
        wifiCredentials: WiFiProvisioningCredentials?,
        portPath: String
    ) {
        pairAttempts += 1
    }

    func pairAttemptCount() -> Int {
        pairAttempts
    }
}

private actor RejectingPairingSerialClient: DeviceSerialPairing {
    func identify(portPath: String) -> DeviceIdentity {
        DeviceIdentity(
            deviceID: "vs-001122334455",
            model: "M5Stack StickS3",
            firmwareVersion: "0.2.0-dev",
            protocolVersion: 2,
            pairingID: nil,
            pairingSchemaVersion: nil,
            wifiConfigured: nil
        )
    }

    func pair(
        identity: DeviceIdentity,
        material: PairingMaterial,
        bridgeID: String,
        fallbackHost: String,
        wifiCredentials: WiFiProvisioningCredentials?,
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
