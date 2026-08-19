import Foundation
import Testing

@Suite("Native Swift Bridge state and quota compatibility")
struct NativeBridgeStateTests {
    @Test("bridge state never serializes remote battery")
    func batteryIsMacPrivate() {
        let state = NativeBridgeStateModel(json: [
            "wifi": true,
            "battery": 82,
            "codex": ["status": "RUNNING", "project": "VibeStick"],
        ])
        #expect(state.json()["battery"] is NSNull)
    }

    @Test("legacy Codex block populates generic provider and dynamic windows")
    func legacyCodexPopulatesProvider() {
        let state = NativeBridgeStateModel(json: [
            "codex": [
                "status": "RUNNING",
                "project": "VibeStick",
                "quota_5h_remaining": 66,
                "quota_7d_remaining": 96,
                "quota_updated_at": "09:38",
            ],
        ])
        let payload = state.json()
        let provider = payload["provider"] as? [String: Any]
        let windows = provider?["quota_windows"] as? [[String: Any]]

        #expect(payload["active_provider"] as? String == "codex")
        #expect(provider?["status"] as? String == "RUNNING")
        #expect(windows?.count == 2)
        #expect(windows?.first?["id"] as? String == "5h")
        #expect(windows?.last?["remaining_percent"] as? Int == 96)
    }

    @Test("explicit provider keeps generic status independent of Codex")
    func explicitProvider() {
        let state = NativeBridgeStateModel(json: [
            "active_provider": "claude",
            "provider": ["id": "claude", "display_name": "Claude", "status": "ERROR"],
            "codex": ["status": "IDLE"],
        ])
        #expect(state.activeProvider == "claude")
        #expect(state.provider.id == "claude")
        #expect(state.provider.status == "ERROR")
        #expect(state.codex.status == "IDLE")
    }

    @Test("invalid status and quota windows fail safe")
    func invalidStateFailsSafe() {
        let state = NativeBridgeStateModel(json: [
            "codex": [
                "status": "PRIVATE_STATUS",
                "quota_windows": [
                    ["id": "", "label": "bad"],
                    ["id": "month", "label": "MONTH", "remaining_percent": 150],
                ],
            ],
            "alert": ["type": "PRIVATE_ALERT", "message": "fictional"],
        ])
        #expect(state.codex.status == "UNKNOWN")
        #expect(state.codex.quotaWindows.count == 1)
        #expect(state.codex.quotaWindows[0].remainingPercent == 100)
        #expect(state.alert.type == "NONE")
    }

    @Test("quota store clamps, round trips, and keeps private permissions")
    func quotaRoundTrip() throws {
        try withNativeBridgeTemporaryDirectory { directory in
            let path = directory.appendingPathComponent("quota.json")
            let store = NativeQuotaStore(path: path)
            try NativeBridgeSecureFile.writeJSONAtomically([
                "quota_5h_remaining": 150,
                "quota_7d_remaining": -20,
                "quota_updated_at": "12:00",
            ], to: path)
            #expect(store.load().quota5HRemaining == 100)
            #expect(store.load().quota7DRemaining == 0)

            let expected = NativeQuotaSnapshot(
                quota5HRemaining: 53,
                quota7DRemaining: 93,
                quotaUpdatedAt: "13:01",
                quotaSource: "codex-app-server",
                quotaObservedAtEpoch: 1_786_520_460
            )
            try store.save(expected)
            #expect(store.load() == expected)
            let permissions = try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? NSNumber
            #expect(permissions?.intValue == 0o600)
        }
    }

    @Test("staleness derives from observation age without dropping quota")
    func quotaStaleness() {
        let snapshot = NativeQuotaSnapshot(
            quota5HRemaining: 20,
            quota7DRemaining: 80,
            quotaObservedAtEpoch: 1_000
        )
        let fresh = snapshot.staleIfOlder(than: 1_800, now: Date(timeIntervalSince1970: 2_000))
        let stale = snapshot.staleIfOlder(than: 1_800, now: Date(timeIntervalSince1970: 3_000))
        #expect(!fresh.quotaStale)
        #expect(stale.quotaStale)
        #expect(stale.quota7DRemaining == 80)
    }

    @Test("account-wide Codex rate-limit bucket is preferred")
    func accountWideRateLimit() throws {
        let observed = Date(timeIntervalSince1970: 1_786_520_500)
        let quota = NativeQuotaSnapshot.fromRateLimitsResult([
            "rateLimits": [
                "limitId": "codex_model",
                "primary": ["usedPercent": 0, "windowDurationMins": 10_080],
            ],
            "rateLimitsByLimitId": [
                "codex": [
                    "primary": ["usedPercent": 18, "windowDurationMins": 300],
                    "secondary": ["usedPercent": 7, "windowDurationMins": 10_080],
                ],
            ],
        ], observedAt: observed)
        #expect(quota?.quota5HRemaining == 82)
        #expect(quota?.quota7DRemaining == 93)
        #expect(quota?.quotaSource == "codex-app-server")
        #expect(quota?.quotaObservedAtEpoch == observed.timeIntervalSince1970)
    }

    @Test("model-only and malformed rate-limit responses are ignored")
    func invalidRateLimits() {
        let modelOnly: [String: Any] = [
            "rateLimits": [
                "limitId": "codex_model",
                "primary": ["usedPercent": 0, "windowDurationMins": 10_080],
            ],
        ]
        #expect(NativeQuotaSnapshot.fromRateLimitsResult(modelOnly) == nil)
        #expect(NativeQuotaSnapshot.fromRateLimitsResult(["rateLimitsByLimitId": ["codex": [:]]]) == nil)
    }

    @Test("state document round trips only normalized fields")
    func stateDocumentRoundTrip() throws {
        try withNativeBridgeTemporaryDirectory { directory in
            let path = directory.appendingPathComponent("state.json")
            let document = NativeBridgeStateDocument(path: path)
            var state = NativeBridgeStateModel()
            state.codex.status = "DONE"
            state.codex.project = "Fictional"
            try document.save(state, now: Date(timeIntervalSince1970: 0))
            let restored = document.load()
            #expect(restored.codex.status == "DONE")
            #expect(restored.codex.project == "Fictional")
            #expect(restored.json()["battery"] is NSNull)
        }
    }
}

private func withNativeBridgeTemporaryDirectory(_ operation: (URL) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("VibeStick-NativeState-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    try operation(directory)
}
