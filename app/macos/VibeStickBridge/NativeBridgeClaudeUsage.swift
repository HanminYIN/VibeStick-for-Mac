import Foundation
import Security

struct NativeClaudeUsage: Equatable {
    var fiveHourUsedPercent: Double?
    var sevenDayUsedPercent: Double?
    var fiveHourResetsAt: Date?
    var sevenDayResetsAt: Date?
}

enum NativeClaudeUsageParser {
    static func usage(from value: Any) -> NativeClaudeUsage? {
        guard let object = value as? [String: Any] else { return nil }
        var fiveHourUsed: Double?
        var sevenDayUsed: Double?
        var fiveHourReset: Date?
        var sevenDayReset: Date?

        if let limits = object["limits"] as? [Any] {
            for case let limit as [String: Any] in limits {
                switch limit["kind"] as? String {
                case "session":
                    fiveHourUsed = number(limit["percent"])
                    fiveHourReset = date(limit["resets_at"])
                case "weekly_all":
                    sevenDayUsed = number(limit["percent"])
                    sevenDayReset = date(limit["resets_at"])
                default:
                    continue
                }
            }
        }
        if fiveHourUsed == nil, let window = object["five_hour"] as? [String: Any] {
            fiveHourUsed = number(window["utilization"])
            fiveHourReset = date(window["resets_at"])
        }
        if sevenDayUsed == nil, let window = object["seven_day"] as? [String: Any] {
            sevenDayUsed = number(window["utilization"])
            sevenDayReset = date(window["resets_at"])
        }
        guard fiveHourUsed != nil || sevenDayUsed != nil else { return nil }
        return NativeClaudeUsage(
            fiveHourUsedPercent: fiveHourUsed,
            sevenDayUsedPercent: sevenDayUsed,
            fiveHourResetsAt: fiveHourReset,
            sevenDayResetsAt: sevenDayReset
        )
    }

    static func snapshot(
        from usage: NativeClaudeUsage,
        fetchedAt: Date,
        now: Date,
        calendar: Calendar = .current
    ) -> NativeQuotaSnapshot {
        let resetExpired = [usage.fiveHourResetsAt, usage.sevenDayResetsAt]
            .compactMap { $0 }
            .contains { $0 <= now }
        let components = calendar.dateComponents([.hour, .minute], from: fetchedAt)
        return NativeQuotaSnapshot(
            quota5HRemaining: remaining(usage.fiveHourUsedPercent),
            quota7DRemaining: remaining(usage.sevenDayUsedPercent),
            quotaUpdatedAt: String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0),
            quotaStale: resetExpired || now.timeIntervalSince(fetchedAt) > 30 * 60,
            quotaSource: "claude-oauth-usage",
            quotaObservedAtEpoch: fetchedAt.timeIntervalSince1970
        )
    }

    static func token(fromCredentialsJSON data: Data, now: Date) -> String? {
        guard data.count <= 262_144,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = object["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else { return nil }
        let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.utf8.count <= 16_384 else { return nil }
        if let expires = number(oauth["expiresAt"]),
           expires <= now.timeIntervalSince1970 * 1_000 {
            return nil
        }
        return normalized
    }

    private static func remaining(_ used: Double?) -> Int? {
        guard let used, used.isFinite else { return nil }
        return min(100, max(0, Int((100 - used).rounded())))
    }

    private static func number(_ value: Any?) -> Double? {
        guard let value, !(value is Bool), let number = value as? NSNumber,
              number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }

    private static func date(_ value: Any?) -> Date? {
        guard let value = value as? String, !value.isEmpty else { return nil }
        return NativeISO8601DateParser.parse(value)
    }
}

protocol NativeClaudeUsageTransport: AnyObject {
    func fetch(token: String, timeout: TimeInterval) -> Any?
}

private final class NativeClaudeURLSessionResult: @unchecked Sendable {
    let lock = NSLock()
    var data: Data?
    var response: URLResponse?
}

final class NativeClaudeURLSessionTransport: NativeClaudeUsageTransport {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let maximumResponseBytes = 200_000

    func fetch(token: String, timeout: TimeInterval) -> Any? {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = max(1, min(15, timeout))
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("cli", forHTTPHeaderField: "x-app")
        request.setValue("claude-cli/2.1.187", forHTTPHeaderField: "User-Agent")
        request.setValue("claude_code", forHTTPHeaderField: "anthropic-client-platform")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = request.timeoutInterval
        configuration.timeoutIntervalForResource = request.timeoutInterval
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        let result = NativeClaudeURLSessionResult()
        let semaphore = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: request) { data, response, _ in
            result.lock.lock()
            result.data = data
            result.response = response
            result.lock.unlock()
            semaphore.signal()
        }
        task.resume()
        guard semaphore.wait(timeout: .now() + request.timeoutInterval + 1) == .success else {
            task.cancel()
            session.invalidateAndCancel()
            return nil
        }
        session.finishTasksAndInvalidate()
        result.lock.lock()
        defer { result.lock.unlock() }
        guard let response = result.response as? HTTPURLResponse,
              response.statusCode == 200,
              response.url?.scheme == "https",
              response.url?.host == Self.endpoint.host,
              let data = result.data,
              data.count <= Self.maximumResponseBytes else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }
}

struct NativeClaudeUsageSettings: Equatable {
    let enabled: Bool
    let interval: TimeInterval

    init(environment: [String: String]) {
        let rawEnabled = environment["VIBE_STICK_CLAUDE_USAGE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        enabled = ["1", "true", "yes", "on"].contains(rawEnabled)
        let requested = Double(environment["VIBE_STICK_CLAUDE_USAGE_INTERVAL_SECONDS"] ?? "")
        interval = max(30, requested.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 300)
    }
}

final class NativeClaudeCredentialResolver {
    static let keychainService = "Claude Code-credentials"

    private let environment: [String: String]
    private let homeDirectory: URL
    private let now: () -> Date

    init(
        environment: [String: String],
        homeDirectory: URL,
        now: @escaping () -> Date = Date.init
    ) {
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.now = now
    }

    func token() -> String? {
        if let value = environment["CLAUDE_CODE_OAUTH_TOKEN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty, value.utf8.count <= 16_384 {
            return value
        }
        if let data = keychainCredentials(),
           let value = NativeClaudeUsageParser.token(fromCredentialsJSON: data, now: now()) {
            return value
        }
        let path = homeDirectory.appendingPathComponent(".claude/.credentials.json")
        guard let data = try? NativeBridgeSecureFile.readData(at: path, maximumBytes: 262_144) else {
            return nil
        }
        return NativeClaudeUsageParser.token(fromCredentialsJSON: data, now: now())
    }

    private func keychainCredentials() -> Data? {
        guard let account = environment["USER"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !account.isEmpty else { return nil }
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.keychainService,
            kSecAttrAccount: account,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecReturnData: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              data.count <= 262_144 else { return nil }
        return data
    }
}

final class NativeClaudeUsageClient {
    private let transport: NativeClaudeUsageTransport
    private let resolveToken: () -> String?
    private let now: () -> Date
    private let timeout: TimeInterval

    init(
        transport: NativeClaudeUsageTransport = NativeClaudeURLSessionTransport(),
        resolveToken: @escaping () -> String?,
        now: @escaping () -> Date = Date.init,
        timeout: TimeInterval = 5
    ) {
        self.transport = transport
        self.resolveToken = resolveToken
        self.now = now
        self.timeout = max(1, min(15, timeout))
    }

    func fetch() -> NativeQuotaSnapshot? {
        guard let token = resolveToken(),
              let value = transport.fetch(token: token, timeout: timeout),
              let usage = NativeClaudeUsageParser.usage(from: value) else { return nil }
        let fetchedAt = now()
        return NativeClaudeUsageParser.snapshot(from: usage, fetchedAt: fetchedAt, now: fetchedAt)
    }
}
