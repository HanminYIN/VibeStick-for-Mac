import Foundation
import Testing

@Suite("Native Swift Bridge Claude usage")
struct NativeBridgeClaudeUsageTests {
    @Test("documented response shapes become remaining percentages")
    func parsesUsage() throws {
        let response: [String: Any] = [
            "limits": [
                ["kind": "session", "percent": 34, "resets_at": "2026-08-20T14:50:00.000Z"],
                ["kind": "weekly_all", "percent": 4, "resets_at": "2026-08-27T10:00:00Z"],
            ],
        ]
        let usage = try #require(NativeClaudeUsageParser.usage(from: response))
        let now = Date(timeIntervalSince1970: 1_787_137_200)
        let snapshot = NativeClaudeUsageParser.snapshot(
            from: usage,
            fetchedAt: now,
            now: now,
            calendar: Calendar(identifier: .gregorian)
        )
        #expect(snapshot.quota5HRemaining == 66)
        #expect(snapshot.quota7DRemaining == 96)
        #expect(snapshot.quotaSource == "claude-oauth-usage")
        #expect(!snapshot.quotaStale)
    }

    @Test("top-level fallback clamps and rounds percentages")
    func fallbackUsage() throws {
        let usage = try #require(NativeClaudeUsageParser.usage(from: [
            "five_hour": ["utilization": 12.5],
            "seven_day": ["utilization": 100.4],
        ]))
        let now = Date(timeIntervalSince1970: 1_787_137_200)
        let snapshot = NativeClaudeUsageParser.snapshot(from: usage, fetchedAt: now, now: now)
        #expect(snapshot.quota5HRemaining == 88)
        #expect(snapshot.quota7DRemaining == 0)
    }

    @Test("expired reset or old fetch is stale")
    func staleUsage() throws {
        let usage = try #require(NativeClaudeUsageParser.usage(from: [
            "five_hour": ["utilization": 50, "resets_at": "2026-01-01T00:00:00Z"],
        ]))
        let fetched = Date(timeIntervalSince1970: 1_787_130_000)
        let snapshot = NativeClaudeUsageParser.snapshot(
            from: usage,
            fetchedAt: fetched,
            now: fetched.addingTimeInterval(1_801)
        )
        #expect(snapshot.quotaStale)
    }

    @Test("unknown response is rejected")
    func unknownResponse() {
        #expect(NativeClaudeUsageParser.usage(from: ["limits": [["kind": "unknown", "percent": 10]]]) == nil)
        #expect(NativeClaudeUsageParser.usage(from: ["five_hour": ["utilization": true]]) == nil)
    }

    @Test("credential JSON rejects expiration and oversized tokens")
    func credentialParsing() throws {
        let valid = try JSONSerialization.data(withJSONObject: [
            "claudeAiOauth": ["accessToken": "fixture-token", "expiresAt": 2_000_000],
        ])
        #expect(NativeClaudeUsageParser.token(
            fromCredentialsJSON: valid,
            now: Date(timeIntervalSince1970: 1_000)
        ) == "fixture-token")
        #expect(NativeClaudeUsageParser.token(
            fromCredentialsJSON: valid,
            now: Date(timeIntervalSince1970: 3_000)
        ) == nil)
        let oversized = try JSONSerialization.data(withJSONObject: [
            "claudeAiOauth": ["accessToken": String(repeating: "x", count: 16_385)],
        ])
        #expect(NativeClaudeUsageParser.token(
            fromCredentialsJSON: oversized,
            now: Date(timeIntervalSince1970: 1)
        ) == nil)
    }

    @Test("usage remains opt-in and polling is bounded")
    func settings() {
        #expect(!NativeClaudeUsageSettings(environment: [:]).enabled)
        #expect(NativeClaudeUsageSettings(environment: [:]).interval == 300)
        #expect(NativeClaudeUsageSettings(environment: [
            "VIBE_STICK_CLAUDE_USAGE": "yes",
            "VIBE_STICK_CLAUDE_USAGE_INTERVAL_SECONDS": "1",
        ]) == NativeClaudeUsageSettings(environment: [
            "VIBE_STICK_CLAUDE_USAGE": "on",
            "VIBE_STICK_CLAUDE_USAGE_INTERVAL_SECONDS": "30",
        ]))
    }

    @Test("client uses only injected token and transport")
    func injectedClient() {
        let transport = FictionalClaudeTransport(result: [
            "five_hour": ["utilization": 20],
            "seven_day": ["utilization": 70],
        ])
        let now = Date(timeIntervalSince1970: 1_787_137_200)
        let client = NativeClaudeUsageClient(
            transport: transport,
            resolveToken: { "fixture-secret-never-persist" },
            now: { now }
        )
        let snapshot = client.fetch()
        #expect(snapshot?.quota5HRemaining == 80)
        #expect(snapshot?.quota7DRemaining == 30)
        #expect(transport.tokens == ["fixture-secret-never-persist"])
        #expect(transport.timeouts == [5])
    }

    @Test("missing token and failed response stay unknown")
    func failureIsUnknown() {
        let transport = FictionalClaudeTransport(result: [:])
        let noToken = NativeClaudeUsageClient(transport: transport, resolveToken: { nil })
        #expect(noToken.fetch() == nil)
        #expect(transport.tokens.isEmpty)

        let invalid = NativeClaudeUsageClient(transport: transport, resolveToken: { "fixture" })
        #expect(invalid.fetch() == nil)
    }
}

private final class FictionalClaudeTransport: NativeClaudeUsageTransport {
    let result: Any
    private(set) var tokens: [String] = []
    private(set) var timeouts: [TimeInterval] = []

    init(result: Any) { self.result = result }

    func fetch(token: String, timeout: TimeInterval) -> Any? {
        tokens.append(token)
        timeouts.append(timeout)
        return result
    }
}
