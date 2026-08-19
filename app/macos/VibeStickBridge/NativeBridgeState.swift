import Foundation

struct NativeQuotaWindow: Equatable {
    let id: String
    let label: String
    let remainingPercent: Int?
    let updatedAt: String
    let stale: Bool

    var json: [String: Any] {
        [
            "id": id,
            "label": label,
            "remaining_percent": jsonNullable(remainingPercent),
            "updated_at": updatedAt,
            "stale": stale,
        ]
    }
}

struct NativeQuotaSnapshot: Equatable {
    var quota5HRemaining: Int?
    var quota7DRemaining: Int?
    var quotaUpdatedAt: String
    var quotaStale: Bool
    var quotaSource: String
    var quotaObservedAtEpoch: Double

    init(
        quota5HRemaining: Int? = nil,
        quota7DRemaining: Int? = nil,
        quotaUpdatedAt: String = "",
        quotaStale: Bool = false,
        quotaSource: String = "",
        quotaObservedAtEpoch: Double = 0
    ) {
        self.quota5HRemaining = quota5HRemaining.map { min(100, max(0, $0)) }
        self.quota7DRemaining = quota7DRemaining.map { min(100, max(0, $0)) }
        self.quotaUpdatedAt = quotaUpdatedAt
        self.quotaStale = quotaStale
        self.quotaSource = String(quotaSource.prefix(64))
        self.quotaObservedAtEpoch = max(0, quotaObservedAtEpoch)
    }

    init(json: [String: Any]) {
        self.init(
            quota5HRemaining: Self.percent(json["quota_5h_remaining"]),
            quota7DRemaining: Self.percent(json["quota_7d_remaining"]),
            quotaUpdatedAt: json["quota_updated_at"] as? String ?? "",
            quotaStale: json["quota_stale"] as? Bool ?? false,
            quotaSource: json["quota_source"] as? String ?? "",
            quotaObservedAtEpoch: Self.number(json["quota_observed_at_epoch"]) ?? 0
        )
    }

    var json: [String: Any] {
        [
            "quota_5h_remaining": jsonNullable(quota5HRemaining),
            "quota_7d_remaining": jsonNullable(quota7DRemaining),
            "quota_updated_at": quotaUpdatedAt,
            "quota_stale": quotaStale,
            "quota_source": quotaSource,
            "quota_observed_at_epoch": quotaObservedAtEpoch,
        ]
    }

    var hasQuota: Bool { quota5HRemaining != nil || quota7DRemaining != nil }

    func staleIfOlder(than seconds: TimeInterval, now: Date) -> NativeQuotaSnapshot {
        guard hasQuota, quotaObservedAtEpoch > 0,
              now.timeIntervalSince1970 - quotaObservedAtEpoch > seconds else {
            return self
        }
        var copy = self
        copy.quotaStale = true
        return copy
    }

    static func fromRateLimitsResult(
        _ value: Any,
        observedAt: Date = Date(),
        calendar: Calendar = .current
    ) -> NativeQuotaSnapshot? {
        guard let result = value as? [String: Any] else { return nil }
        var snapshot: [String: Any]?
        if let buckets = result["rateLimitsByLimitId"] as? [String: Any] {
            snapshot = buckets["codex"] as? [String: Any]
        }
        if snapshot == nil,
           let historical = result["rateLimits"] as? [String: Any],
           ((historical["limitId"] as? String) ?? "codex").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "codex" {
            snapshot = historical
        }
        guard let snapshot else { return nil }

        var fiveHour: Int?
        var sevenDay: Int?
        for name in ["primary", "secondary"] {
            guard let window = snapshot[name] as? [String: Any],
                  let used = number(window["usedPercent"]),
                  let minutes = integer(window["windowDurationMins"]) else {
                continue
            }
            let remaining = min(100, max(0, Int((100 - used).rounded())))
            if minutes == 300 { fiveHour = remaining }
            if minutes == 10_080 { sevenDay = remaining }
        }
        guard fiveHour != nil || sevenDay != nil else { return nil }

        let components = calendar.dateComponents([.hour, .minute], from: observedAt)
        let updatedAt = String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
        return NativeQuotaSnapshot(
            quota5HRemaining: fiveHour,
            quota7DRemaining: sevenDay,
            quotaUpdatedAt: updatedAt,
            quotaStale: false,
            quotaSource: "codex-app-server",
            quotaObservedAtEpoch: observedAt.timeIntervalSince1970
        )
    }

    private static func percent(_ value: Any?) -> Int? {
        guard let number = number(value) else { return nil }
        return min(100, max(0, Int(number)))
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = number(value), number.rounded() == number else { return nil }
        return Int(number)
    }

    private static func number(_ value: Any?) -> Double? {
        guard let value, !(value is Bool) else { return nil }
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }
}

final class NativeQuotaStore {
    private let path: URL

    init(path: URL) {
        self.path = path
    }

    func load() -> NativeQuotaSnapshot {
        guard let data = try? NativeBridgeSecureFile.readData(at: path, maximumBytes: 16_384),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return NativeQuotaSnapshot()
        }
        return NativeQuotaSnapshot(json: object)
    }

    func save(_ snapshot: NativeQuotaSnapshot) throws {
        try NativeBridgeSecureFile.writeJSONAtomically(snapshot.json, to: path)
    }
}

struct NativeAgentState: Equatable {
    static let validStatuses: Set<String> = [
        "IDLE", "RUNNING", "DONE", "APPROVAL", "ERROR", "OFFLINE", "UNKNOWN",
    ]

    var id: String
    var displayName: String
    var implemented: Bool
    var status: String
    var project: String
    var quota5HRemaining: Int?
    var quota7DRemaining: Int?
    var quotaUpdatedAt: String
    var quotaStale: Bool
    var quotaWindows: [NativeQuotaWindow]

    init(
        id: String = "codex",
        displayName: String = "Codex",
        implemented: Bool = true,
        status: String = "IDLE",
        project: String = "vibestick",
        quota5HRemaining: Int? = nil,
        quota7DRemaining: Int? = nil,
        quotaUpdatedAt: String = "",
        quotaStale: Bool = false,
        quotaWindows: [NativeQuotaWindow] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.implemented = implemented
        self.status = Self.validStatuses.contains(status) ? status : "UNKNOWN"
        self.project = project
        self.quota5HRemaining = quota5HRemaining
        self.quota7DRemaining = quota7DRemaining
        self.quotaUpdatedAt = quotaUpdatedAt
        self.quotaStale = quotaStale
        self.quotaWindows = quotaWindows
    }

    init(json: [String: Any], fallback: NativeAgentState? = nil) {
        let base = fallback ?? NativeAgentState()
        self.init(
            id: json["id"] as? String ?? base.id,
            displayName: json["display_name"] as? String ?? base.displayName,
            implemented: json["implemented"] as? Bool ?? base.implemented,
            status: json["status"] as? String ?? base.status,
            project: json["project"] as? String ?? base.project,
            quota5HRemaining: Self.percent(json["quota_5h_remaining"]),
            quota7DRemaining: Self.percent(json["quota_7d_remaining"]),
            quotaUpdatedAt: json["quota_updated_at"] as? String ?? "",
            quotaStale: json["quota_stale"] as? Bool ?? false,
            quotaWindows: Self.windows(json["quota_windows"])
        )
    }

    var json: [String: Any] {
        let windows = quotaWindows.isEmpty ? legacyWindows : quotaWindows
        return [
            "id": id,
            "display_name": displayName,
            "implemented": implemented,
            "status": status,
            "project": project,
            "quota_5h_remaining": jsonNullable(quota5HRemaining),
            "quota_7d_remaining": jsonNullable(quota7DRemaining),
            "quota_updated_at": quotaUpdatedAt,
            "quota_stale": quotaStale,
            "quota_windows": windows.map(\.json),
        ]
    }

    private var legacyWindows: [NativeQuotaWindow] {
        var result: [NativeQuotaWindow] = []
        if let quota5HRemaining {
            result.append(.init(id: "5h", label: "5H", remainingPercent: quota5HRemaining, updatedAt: quotaUpdatedAt, stale: quotaStale))
        }
        if let quota7DRemaining {
            result.append(.init(id: "7d", label: "7D", remainingPercent: quota7DRemaining, updatedAt: quotaUpdatedAt, stale: quotaStale))
        }
        return result
    }

    private static func percent(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, !(value is Bool) else { return nil }
        return min(100, max(0, Int(number.doubleValue.rounded())))
    }

    private static func windows(_ value: Any?) -> [NativeQuotaWindow] {
        guard let values = value as? [Any] else { return [] }
        return values.compactMap { item in
            guard let object = item as? [String: Any],
                  let rawID = object["id"] as? String,
                  let rawLabel = object["label"] as? String,
                  !rawID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !rawLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return NativeQuotaWindow(
                id: String(rawID.prefix(32)),
                label: String(rawLabel.prefix(16)),
                remainingPercent: percent(object["remaining_percent"]),
                updatedAt: String((object["updated_at"] as? String ?? "").prefix(32)),
                stale: object["stale"] as? Bool ?? false
            )
        }.prefix(4).map { $0 }
    }
}

struct NativeAlertState: Equatable {
    var eventID: String
    var type: String
    var message: String

    init(eventID: String = "", type: String = "NONE", message: String = "") {
        self.eventID = eventID
        self.type = ["NONE", "DONE", "APPROVAL", "ERROR"].contains(type) ? type : "NONE"
        self.message = message
    }

    var json: [String: Any] {
        ["event_id": eventID, "type": type, "message": message]
    }
}

struct NativeBridgeStateModel: Equatable {
    var wifi: Bool
    var ble: Bool
    var activeProvider: String
    var provider: NativeAgentState
    var codex: NativeAgentState
    var alert: NativeAlertState

    init(
        wifi: Bool = true,
        ble: Bool = false,
        activeProvider: String = "codex",
        provider: NativeAgentState = NativeAgentState(),
        codex: NativeAgentState = NativeAgentState(),
        alert: NativeAlertState = NativeAlertState()
    ) {
        self.wifi = wifi
        self.ble = ble
        self.activeProvider = activeProvider
        self.provider = provider
        self.codex = codex
        self.alert = alert
    }

    init(json: [String: Any]) {
        let codexObject = json["codex"] as? [String: Any] ?? [:]
        let codex = NativeAgentState(json: codexObject)
        let providerObject = json["provider"] as? [String: Any]
        let provider = providerObject.map { NativeAgentState(json: $0, fallback: codex) } ?? codex
        let alertObject = json["alert"] as? [String: Any] ?? [:]
        self.init(
            wifi: json["wifi"] as? Bool ?? true,
            ble: json["ble"] as? Bool ?? false,
            activeProvider: json["active_provider"] as? String ?? provider.id,
            provider: provider,
            codex: codex,
            alert: NativeAlertState(
                eventID: alertObject["event_id"] as? String ?? "",
                type: alertObject["type"] as? String ?? "NONE",
                message: alertObject["message"] as? String ?? ""
            )
        )
    }

    func json(now: Date = Date(), calendar: Calendar = .current) -> [String: Any] {
        let components = calendar.dateComponents([.hour, .minute], from: now)
        return [
            "time": String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0),
            "wifi": wifi,
            "ble": ble,
            "battery": NSNull(),
            "active_provider": activeProvider,
            "provider": provider.json,
            "codex": codex.json,
            "alert": alert.json,
        ]
    }
}

final class NativeBridgeStateDocument {
    private let path: URL

    init(path: URL) {
        self.path = path
    }

    func load() -> NativeBridgeStateModel {
        guard let data = try? NativeBridgeSecureFile.readData(at: path, maximumBytes: 262_144),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return NativeBridgeStateModel()
        }
        return NativeBridgeStateModel(json: object)
    }

    func save(_ state: NativeBridgeStateModel, now: Date = Date()) throws {
        try NativeBridgeSecureFile.writeJSONAtomically(state.json(now: now), to: path)
    }
}

private func jsonNullable<T>(_ value: T?) -> Any {
    value.map { $0 as Any } ?? NSNull()
}
