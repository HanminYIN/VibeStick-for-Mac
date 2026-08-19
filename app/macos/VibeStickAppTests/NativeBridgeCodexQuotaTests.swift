import Foundation
import Testing

@Suite("Native Swift Bridge Codex account quota")
struct NativeBridgeCodexQuotaTests {
    private let observedAt = Date(timeIntervalSince1970: 1_787_090_000)

    @Test("modern account-wide response maps 5 hour and 7 day windows")
    func modernResponse() throws {
        let result: [String: Any] = [
            "rateLimitsByLimitId": [
                "codex": [
                    "primary": ["usedPercent": 12, "windowDurationMins": 300],
                    "secondary": ["usedPercent": 34, "windowDurationMins": 10_080],
                ],
                "codex_model": [
                    "primary": ["usedPercent": 99, "windowDurationMins": 300],
                ],
            ],
        ]
        let snapshot = try #require(NativeCodexRateLimitParser.snapshot(
            from: result,
            observedAt: observedAt,
            calendar: utcCalendar()
        ))
        #expect(snapshot.quota5HRemaining == 88)
        #expect(snapshot.quota7DRemaining == 66)
        #expect(snapshot.quotaSource == "codex-app-server")
        #expect(snapshot.quotaObservedAtEpoch == observedAt.timeIntervalSince1970)
    }

    @Test("historical response remains compatible and percentages are clamped")
    func historicalResponse() throws {
        let snapshot = try #require(NativeCodexRateLimitParser.snapshot(from: [
            "rateLimits": [
                "limitId": "codex",
                "primary": ["usedPercent": -10, "windowDurationMins": 300],
                "secondary": ["usedPercent": 150, "windowDurationMins": 10_080],
            ],
        ], observedAt: observedAt, calendar: utcCalendar()))
        #expect(snapshot.quota5HRemaining == 100)
        #expect(snapshot.quota7DRemaining == 0)
    }

    @Test("named-model bool and malformed responses are rejected")
    func invalidResponses() {
        #expect(NativeCodexRateLimitParser.snapshot(from: [
            "rateLimits": [
                "limitId": "codex_model",
                "primary": ["usedPercent": 10, "windowDurationMins": 300],
            ],
        ]) == nil)
        #expect(NativeCodexRateLimitParser.snapshot(from: [
            "rateLimitsByLimitId": [
                "codex": [
                    "primary": ["usedPercent": true, "windowDurationMins": 300],
                ],
            ],
        ]) == nil)
    }

    @Test("client uses one injected local transport and returns only quota")
    func injectedTransport() throws {
        let transport = FictionalCodexQuotaTransport(result: [
            "rateLimitsByLimitId": [
                "codex": [
                    "primary": ["usedPercent": 5, "windowDurationMins": 300],
                    "secondary": ["usedPercent": 8, "windowDurationMins": 10_080],
                ],
            ],
            "account": ["email": "must-not-be-returned@example.invalid"],
        ])
        let client = NativeCodexQuotaClient(
            transport: transport,
            resolveExecutable: { URL(fileURLWithPath: "/fictional/Codex.app/codex") },
            now: { self.observedAt },
            timeout: 4
        )
        let snapshot = try #require(client.fetch())
        #expect(snapshot.quota7DRemaining == 92)
        #expect(transport.paths == ["/fictional/Codex.app/codex"])
        #expect(transport.timeouts == [4])
        #expect(!String(describing: snapshot).contains("example.invalid"))
    }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}

private final class FictionalCodexQuotaTransport: NativeCodexQuotaTransport {
    let result: Any?
    private(set) var paths: [String] = []
    private(set) var timeouts: [TimeInterval] = []

    init(result: Any?) { self.result = result }

    func fetchRateLimits(executable: URL, timeout: TimeInterval) -> Any? {
        paths.append(executable.path)
        timeouts.append(timeout)
        return result
    }
}
