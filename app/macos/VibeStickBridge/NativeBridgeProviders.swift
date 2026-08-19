import CryptoKit
import Foundation

struct NativeProviderObservation: Equatable {
    let providerID: String
    let displayName: String
    let online: Bool
    var status: String
    var project: String
    var quota: NativeQuotaSnapshot
    var alertType: String
    var alertMessage: String
    var alertEventID: String
    var latestEventTimestamp: Date?

    var agentState: NativeAgentState {
        NativeAgentState(
            id: providerID,
            displayName: displayName,
            implemented: true,
            status: status,
            project: project,
            quota5HRemaining: quota.quota5HRemaining,
            quota7DRemaining: quota.quota7DRemaining,
            quotaUpdatedAt: quota.quotaUpdatedAt,
            quotaStale: quota.quotaStale
        )
    }

    var hasAlert: Bool {
        ["DONE", "APPROVAL", "ERROR"].contains(alertType) && !alertEventID.isEmpty
    }
}

struct NativeCodexSessionInput {
    let sessionID: String
    let userInitiated: Bool?
    let metadataWorkingDirectory: String?
    let events: [[String: Any]]
}

enum NativeProviderObservationEngine {
    static let runningWindow: TimeInterval = 4 * 60
    static let alertWindow: TimeInterval = 5 * 60
    static let quotaStaleAfter: TimeInterval = 30 * 60

    static func observeCodex(
        sessions: [NativeCodexSessionInput],
        online: Bool,
        fallbackProject: String,
        now: Date = Date()
    ) -> NativeProviderObservation {
        var latestProject: (Date, String)?
        var latestRunningProject: (Date, String)?
        var latestEvent: NativeDatedEvent?
        var latestFallbackEvent: NativeDatedEvent?
        var latestCompletion: NativeAlertCandidate?
        var latestApproval: NativeAlertCandidate?
        var latestError: NativeAlertCandidate?
        var latestQuota: NativeQuotaCandidate?
        var userSessionFound = false
        var userTaskRunning = false

        for input in sessions {
            let session = codexSessionObservation(input, now: now)
            latestQuota = preferredQuota(latestQuota, session.quota)
            if input.userInitiated != true {
                latestFallbackEvent = newerEvent(latestFallbackEvent, session.latestEvent)
                continue
            }

            userSessionFound = true
            latestEvent = newerEvent(latestEvent, session.latestEvent)
            let running = sessionIsRunning(session, now: now)
            userTaskRunning = userTaskRunning || running
            let projectPath = session.latestWorkingDirectory?.1 ?? input.metadataWorkingDirectory
            let projectTimestamp = session.latestEvent?.timestamp ?? session.latestWorkingDirectory?.0
            if let projectPath, let projectTimestamp {
                let candidate = (projectTimestamp, projectName(from: projectPath, fallback: fallbackProject))
                if latestProject == nil || projectTimestamp > latestProject!.0 { latestProject = candidate }
                if running, latestRunningProject == nil || (running && projectTimestamp > latestRunningProject!.0) {
                    latestRunningProject = candidate
                }
            }
            if let completion = session.completion,
               now.timeIntervalSince(completion.timestamp) <= alertWindow,
               completionIsConfirmed(session, completion: completion) {
                latestCompletion = newerAlert(latestCompletion, completion)
            }
            if alertIsCurrent(session, alert: session.approval, now: now) {
                latestApproval = newerAlert(latestApproval, session.approval)
            }
            if alertIsCurrent(session, alert: session.error, now: now) {
                latestError = newerAlert(latestError, session.error)
            }
        }

        if latestEvent == nil, !userSessionFound { latestEvent = latestFallbackEvent }
        let selectedProject = (latestRunningProject ?? latestProject)?.1 ?? fallbackProject
        var selectedAlert = latestError ?? latestApproval ?? latestCompletion
        let status: String
        if !online {
            status = "OFFLINE"
            selectedAlert = nil
        } else if latestError != nil {
            status = "ERROR"
        } else if latestApproval != nil {
            status = "APPROVAL"
        } else if userTaskRunning {
            status = "RUNNING"
        } else if latestCompletion != nil {
            status = "DONE"
        } else if let latestEvent,
                  !["task_complete", "turn_aborted"].contains(latestEvent.type.lowercased()),
                  now.timeIntervalSince(latestEvent.timestamp) <= runningWindow {
            status = "RUNNING"
        } else {
            status = "IDLE"
        }

        let quota = latestQuota?.snapshot ?? NativeQuotaSnapshot()
        return NativeProviderObservation(
            providerID: "codex",
            displayName: "Codex",
            online: online,
            status: status,
            project: selectedProject,
            quota: quota,
            alertType: selectedAlert?.kind ?? "NONE",
            alertMessage: selectedAlert?.message ?? "",
            alertEventID: selectedAlert.map { stableCodexEventID($0) } ?? "",
            latestEventTimestamp: latestEvent?.timestamp
        )
    }

    static func observeClaude(
        events: [[String: Any]],
        online: Bool,
        project: String,
        now: Date = Date()
    ) -> NativeProviderObservation {
        var latestEvent: (Date, String, String)?
        var latestError: (Date, String, String)?
        var latestDone: (Date, String, String)?
        var latestToolUse: (Date, String, String)?
        var sessionModes: [String: (Date, String)] = [:]

        for event in events {
            guard let timestamp = date(event["timestamp"]) else { continue }
            let sessionID = event["sessionId"] as? String ?? ""
            let eventType = event["type"] as? String ?? ""
            if !eventType.isEmpty, latestEvent == nil || timestamp > latestEvent!.0 {
                latestEvent = (timestamp, eventType, sessionID)
            }
            if let mode = event["permissionMode"] as? String, !mode.isEmpty, !sessionID.isEmpty,
               sessionModes[sessionID] == nil || timestamp > sessionModes[sessionID]!.0 {
                sessionModes[sessionID] = (timestamp, mode)
            }
            if claudeHasError(event) {
                let candidate = (timestamp, claudeEventID("claude_error", event: event, timestamp: timestamp), claudeMessage(event).isEmpty ? "Claude task failed or needs attention" : claudeMessage(event))
                if latestError == nil || timestamp > latestError!.0 { latestError = candidate }
            }
            if eventType == "assistant", claudeStopReason(event) == "tool_use" {
                let candidate = (timestamp, claudeEventID("claude_approval", event: event, timestamp: timestamp), sessionID)
                if latestToolUse == nil || timestamp > latestToolUse!.0 { latestToolUse = candidate }
            }
            if eventType == "assistant", claudeTurnComplete(event) {
                let candidate = (timestamp, claudeEventID("claude_done", event: event, timestamp: timestamp), "Claude task completed")
                if latestDone == nil || timestamp > latestDone!.0 { latestDone = candidate }
            }
        }

        func isLatest(_ timestamp: Date) -> Bool {
            latestEvent != nil && timestamp >= latestEvent!.0
        }
        let approvalPending = latestToolUse != nil
            && isLatest(latestToolUse!.0)
            && sessionModes[latestToolUse!.2]?.1 == "default"
            && now.timeIntervalSince(latestToolUse!.0) <= runningWindow

        var status = "IDLE"
        var alertType = "NONE"
        var alertMessage = ""
        var alertEventID = ""
        if !online {
            status = "OFFLINE"
        } else if let error = latestError,
                  isLatest(error.0), now.timeIntervalSince(error.0) <= alertWindow {
            status = "ERROR"
            alertType = "ERROR"
            alertEventID = error.1
            alertMessage = error.2
        } else if approvalPending, let approval = latestToolUse {
            status = "APPROVAL"
            alertType = "APPROVAL"
            alertEventID = approval.1
            alertMessage = "Claude is waiting for approval"
        } else if let done = latestDone,
                  isLatest(done.0), now.timeIntervalSince(done.0) <= alertWindow {
            status = "DONE"
            alertType = "DONE"
            alertEventID = done.1
            alertMessage = done.2
        } else if let latestEvent, now.timeIntervalSince(latestEvent.0) <= runningWindow {
            status = "RUNNING"
        }
        return NativeProviderObservation(
            providerID: "claude",
            displayName: "Claude",
            online: online,
            status: status,
            project: project,
            quota: NativeQuotaSnapshot(),
            alertType: alertType,
            alertMessage: alertMessage,
            alertEventID: alertEventID,
            latestEventTimestamp: latestEvent?.0
        )
    }

    static func selectActiveProvider(
        configured: String,
        lastActive: String,
        codex: NativeProviderObservation,
        claude: NativeProviderObservation
    ) -> String {
        if ["codex", "claude"].contains(configured) { return configured }
        if codex.online && !claude.online { return "codex" }
        if claude.online && !codex.online { return "claude" }
        if codex.online && claude.online {
            if let codexTime = codex.latestEventTimestamp, let claudeTime = claude.latestEventTimestamp {
                return claudeTime > codexTime ? "claude" : "codex"
            }
            if claude.latestEventTimestamp != nil { return "claude" }
            if codex.latestEventTimestamp != nil { return "codex" }
        }
        return ["codex", "claude"].contains(lastActive) ? lastActive : "codex"
    }

    static func selectAlert(
        active: NativeProviderObservation,
        codex: NativeProviderObservation,
        claude: NativeProviderObservation
    ) -> NativeProviderObservation {
        if active.hasAlert { return active }
        if codex.providerID != active.providerID, codex.hasAlert { return codex }
        if claude.providerID != active.providerID, claude.hasAlert { return claude }
        return active
    }

    static func codexProcessRunning(commands: [String]) -> Bool {
        commands.contains { command in
            let lower = command.lowercased()
            return lower.contains("/applications/codex.app/")
                || lower.contains("codex app-server")
                || (lower.contains("/applications/chatgpt.app/contents/resources/codex") && lower.contains(" app-server"))
        }
    }

    static func claudeProcessRunning(commands: [String]) -> Bool {
        commands.contains { command in
            let lower = command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !lower.isEmpty else { return false }
            if lower.contains("claude.app/contents/macos/claude") { return true }
            let executable = lower.split(separator: " ").first.map(String.init) ?? ""
            return URL(fileURLWithPath: executable).lastPathComponent == "claude"
        }
    }
}

final class NativeProviderFileSource {
    func codexSessions(root: URL) -> [NativeCodexSessionInput] {
        let files = sessionFiles(root: root, maximum: 160)
        var user: [NativeCodexSessionInput] = []
        var unknown: [NativeCodexSessionInput] = []
        var internalSessions: [NativeCodexSessionInput] = []
        for file in files {
            let identity = codexIdentity(file)
            let tailBytes = identity.userInitiated == false ? 262_144 : 1_500_000
            let input = NativeCodexSessionInput(
                sessionID: identity.sessionID,
                userInitiated: identity.userInitiated,
                metadataWorkingDirectory: identity.workingDirectory,
                events: jsonLines(try? NativeBridgeSecureFile.readTail(at: file, maximumBytes: tailBytes))
            )
            if identity.userInitiated == true, user.count < 40 { user.append(input) }
            else if identity.userInitiated == nil, unknown.count < 10 { unknown.append(input) }
            else if identity.userInitiated == false, internalSessions.count < 40 { internalSessions.append(input) }
        }
        return user + unknown + internalSessions
    }

    func claudeEvents(root: URL) -> [[String: Any]] {
        sessionFiles(root: root, maximum: 40).flatMap {
            jsonLines(try? NativeBridgeSecureFile.readTail(at: $0, maximumBytes: 1_500_000))
        }
    }

    private func codexIdentity(_ file: URL) -> (sessionID: String, userInitiated: Bool?, workingDirectory: String?) {
        guard let prefix = try? NativeBridgeSecureFile.readPrefix(at: file, maximumBytes: 262_144),
              let lineEnd = prefix.firstIndex(of: 0x0A),
              let event = try? JSONSerialization.jsonObject(with: prefix[..<lineEnd]) as? [String: Any],
              event["type"] as? String == "session_meta",
              let payload = event["payload"] as? [String: Any],
              let sessionID = payload["id"] as? String,
              !sessionID.isEmpty,
              file.lastPathComponent.hasSuffix("\(sessionID).jsonl") else {
            return ("", nil, nil)
        }
        let source = payload["source"]
        let initiated: Bool?
        if let source = source as? [String: Any], source["subagent"] != nil { initiated = false }
        else if source == nil || source is NSNull { initiated = nil }
        else { initiated = true }
        return (sessionID, initiated, payload["cwd"] as? String)
    }

    private func sessionFiles(root: URL, maximum: Int) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var candidates: [(URL, Date)] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            candidates.append((url, values.contentModificationDate ?? .distantPast))
        }
        return candidates.sorted { $0.1 > $1.1 }.prefix(maximum).map(\.0)
    }

    private func jsonLines(_ data: Data?) -> [[String: Any]] {
        guard let data, let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \Character.isNewline).compactMap { line in
            guard line.first == "{",
                  let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return object
        }
    }
}

enum NativeSystemProcessSource {
    static func commands() -> [String] {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "command="]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return [] }
        return String(decoding: output, as: UTF8.self)
            .split(whereSeparator: \Character.isNewline).map(String.init)
    }
}

private struct NativeDatedEvent {
    let timestamp: Date
    let type: String
    let message: String
}

private struct NativeAlertCandidate {
    let timestamp: Date
    let kind: String
    let message: String
    let eventKey: String
}

private struct NativeQuotaCandidate {
    let timestamp: Date
    let snapshot: NativeQuotaSnapshot
    let accountWide: Bool
}

private struct NativeCodexSessionObservation {
    var latestEvent: NativeDatedEvent?
    var latestWorkingDirectory: (Date, String)?
    var latestLifecycle: (Date, String)?
    var activeTurns: Set<String> = []
    var completion: NativeAlertCandidate?
    var approval: NativeAlertCandidate?
    var error: NativeAlertCandidate?
    var quota: NativeQuotaCandidate?
}

private func codexSessionObservation(_ input: NativeCodexSessionInput, now: Date) -> NativeCodexSessionObservation {
    var result = NativeCodexSessionObservation()
    for event in input.events {
        guard let timestamp = date(event["timestamp"]) else { continue }
        let topType = event["type"] as? String ?? ""
        let payload = event["payload"] as? [String: Any] ?? [:]
        let payloadType = payload["type"] as? String ?? topType
        let candidateType = payloadType.isEmpty ? topType : payloadType
        let message = payload["message"] as? String ?? ""
        let turnID = payload["turn_id"] as? String ?? ""
        if topType == "turn_context", let workingDirectory = payload["cwd"] as? String, !workingDirectory.isEmpty {
            result.latestWorkingDirectory = (timestamp, workingDirectory)
        }
        if !candidateType.isEmpty, result.latestEvent == nil || timestamp > result.latestEvent!.timestamp {
            result.latestEvent = .init(timestamp: timestamp, type: candidateType, message: message)
        }
        let normalized = candidateType.lowercased()
        if normalized == "task_started" {
            result.latestLifecycle = (timestamp, normalized)
            if !turnID.isEmpty { result.activeTurns.insert(turnID) }
        } else if ["task_complete", "turn_aborted"].contains(normalized) {
            result.latestLifecycle = (timestamp, normalized)
            if !turnID.isEmpty { result.activeTurns.remove(turnID) }
        }
        if let quota = codexQuota(payload, timestamp: timestamp, now: now) {
            result.quota = preferredQuota(result.quota, quota)
        }
        if let alert = codexAlert(candidateType, payload: payload, sessionID: input.sessionID, turnID: turnID, timestamp: timestamp) {
            if alert.kind == "DONE" { result.completion = newerAlert(result.completion, alert) }
            if alert.kind == "APPROVAL" { result.approval = newerAlert(result.approval, alert) }
            if alert.kind == "ERROR" { result.error = newerAlert(result.error, alert) }
        }
    }
    return result
}

private func codexQuota(_ payload: [String: Any], timestamp: Date, now: Date) -> NativeQuotaCandidate? {
    guard payload["type"] as? String == "token_count",
          let limits = payload["rate_limits"] as? [String: Any] else { return nil }
    var fiveHour: Int?
    var sevenDay: Int?
    for name in ["primary", "secondary"] {
        guard let window = limits[name] as? [String: Any],
              let number = window["used_percent"] as? NSNumber,
              !(window["used_percent"] is Bool),
              let minutesNumber = window["window_minutes"] as? NSNumber,
              !(window["window_minutes"] is Bool),
              minutesNumber.doubleValue.isFinite,
              minutesNumber.doubleValue.rounded() == minutesNumber.doubleValue else { continue }
        let minutes = minutesNumber.intValue
        let remaining = min(100, max(0, Int((100 - number.doubleValue).rounded())))
        if minutes == 300 { fiveHour = remaining }
        if minutes == 10_080 { sevenDay = remaining }
    }
    guard fiveHour != nil || sevenDay != nil else { return nil }
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm"
    let snapshot = NativeQuotaSnapshot(
        quota5HRemaining: fiveHour,
        quota7DRemaining: sevenDay,
        quotaUpdatedAt: formatter.string(from: timestamp),
        quotaStale: now.timeIntervalSince(timestamp) > NativeProviderObservationEngine.quotaStaleAfter,
        quotaSource: "codex-session-log",
        quotaObservedAtEpoch: timestamp.timeIntervalSince1970
    )
    let limitID = (limits["limit_id"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return .init(timestamp: timestamp, snapshot: snapshot, accountWide: limitID.isEmpty || limitID == "codex")
}

private func codexAlert(
    _ type: String,
    payload: [String: Any],
    sessionID: String,
    turnID: String,
    timestamp: Date
) -> NativeAlertCandidate? {
    let normalized = type.lowercased()
    let kind: String
    let message: String
    if normalized == "task_complete" { kind = "DONE"; message = "Codex task completed" }
    else if normalized.contains("approval") || normalized.contains("permission") { kind = "APPROVAL"; message = "Codex is waiting for approval" }
    else if normalized == "error" || normalized == "agent_error" || normalized.hasSuffix("_error") {
        kind = "ERROR"; message = payload["message"] as? String ?? payload["error"] as? String ?? "Codex task failed or needs attention"
    } else if payload["rate_limit_reached_type"] != nil {
        kind = "ERROR"; message = "Codex quota limit reached"
    } else { return nil }
    let formatter = ISO8601DateFormatter()
    let key = "\(sessionID):\(turnID.isEmpty ? formatter.string(from: timestamp) : turnID):\(kind)"
    return .init(timestamp: timestamp, kind: kind, message: message, eventKey: key)
}

private func sessionIsRunning(_ session: NativeCodexSessionObservation, now: Date) -> Bool {
    if !session.activeTurns.isEmpty { return true }
    if let lifecycle = session.latestLifecycle,
       ["task_complete", "turn_aborted"].contains(lifecycle.1),
       session.latestEvent == nil || lifecycle.0 >= session.latestEvent!.timestamp { return false }
    return session.latestEvent.map { now.timeIntervalSince($0.timestamp) <= NativeProviderObservationEngine.runningWindow } ?? false
}

private func alertIsCurrent(_ session: NativeCodexSessionObservation, alert: NativeAlertCandidate?, now: Date) -> Bool {
    guard let alert, now.timeIntervalSince(alert.timestamp) <= NativeProviderObservationEngine.alertWindow else { return false }
    return session.latestEvent == nil || alert.timestamp >= session.latestEvent!.timestamp
}

private func completionIsConfirmed(_ session: NativeCodexSessionObservation, completion: NativeAlertCandidate) -> Bool {
    if session.latestEvent == nil || completion.timestamp >= session.latestEvent!.timestamp { return true }
    return session.latestLifecycle?.1 == "task_started" && session.latestLifecycle!.0 > completion.timestamp
}

private func newerEvent(_ current: NativeDatedEvent?, _ candidate: NativeDatedEvent?) -> NativeDatedEvent? {
    guard let candidate else { return current }
    return current == nil || candidate.timestamp > current!.timestamp ? candidate : current
}

private func newerAlert(_ current: NativeAlertCandidate?, _ candidate: NativeAlertCandidate?) -> NativeAlertCandidate? {
    guard let candidate else { return current }
    return current == nil || candidate.timestamp > current!.timestamp ? candidate : current
}

private func preferredQuota(_ current: NativeQuotaCandidate?, _ candidate: NativeQuotaCandidate?) -> NativeQuotaCandidate? {
    guard let candidate else { return current }
    guard let current else { return candidate }
    if candidate.accountWide != current.accountWide { return candidate.accountWide ? candidate : current }
    return candidate.timestamp > current.timestamp ? candidate : current
}

private func stableCodexEventID(_ alert: NativeAlertCandidate) -> String {
    let digest = SHA256.hash(data: Data(alert.eventKey.utf8)).map { String(format: "%02x", $0) }.joined()
    return "evt_\(digest.prefix(16))_\(alert.kind.lowercased())"
}

private func projectName(from path: String, fallback: String) -> String {
    let name = URL(fileURLWithPath: path).lastPathComponent
    return name.isEmpty ? fallback : name
}

private func date(_ value: Any?) -> Date? {
    guard let string = value as? String, !string.isEmpty else { return nil }
    return NativeISO8601DateParser.parse(string)
}

enum NativeISO8601DateParser {
    static func parse(_ value: String) -> Date? {
        let bytes = Array(value.utf8)
        guard bytes.count >= 20,
              bytes[4] == 45, bytes[7] == 45,
              bytes[10] == 84 || bytes[10] == 32,
              bytes[13] == 58, bytes[16] == 58,
              let year = integer(bytes, 0, 4),
              let month = integer(bytes, 5, 2),
              let day = integer(bytes, 8, 2),
              let hour = integer(bytes, 11, 2),
              let minute = integer(bytes, 14, 2),
              let second = integer(bytes, 17, 2) else { return nil }

        var index = 19
        var fraction: TimeInterval = 0
        if index < bytes.count, bytes[index] == 46 {
            index += 1
            let start = index
            while index < bytes.count, bytes[index] >= 48, bytes[index] <= 57 { index += 1 }
            guard index > start else { return nil }
            var divisor = 10.0
            for digit in bytes[start..<index] {
                fraction += Double(digit - 48) / divisor
                divisor *= 10
            }
        }

        let offset: TimeInterval
        if index < bytes.count, bytes[index] == 90 || bytes[index] == 122 {
            offset = 0
            index += 1
        } else if index < bytes.count, bytes[index] == 43 || bytes[index] == 45 {
            let sign: TimeInterval = bytes[index] == 43 ? 1 : -1
            index += 1
            guard let offsetHour = integer(bytes, index, 2) else { return nil }
            index += 2
            if index < bytes.count, bytes[index] == 58 { index += 1 }
            guard let offsetMinute = integer(bytes, index, 2),
                  offsetHour <= 23, offsetMinute <= 59 else { return nil }
            index += 2
            offset = sign * TimeInterval(offsetHour * 3_600 + offsetMinute * 60)
        } else {
            return nil
        }
        guard index == bytes.count,
              (1...12).contains(month), (1...31).contains(day),
              (0...23).contains(hour), (0...59).contains(minute),
              (0...60).contains(second) else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let base = calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: min(59, second)
        )) else { return nil }
        let leapAdjustment: TimeInterval = second == 60 ? 1 : 0
        return base.addingTimeInterval(fraction + leapAdjustment - offset)
    }

    private static func integer(_ bytes: [UInt8], _ start: Int, _ length: Int) -> Int? {
        guard start >= 0, length > 0, start + length <= bytes.count else { return nil }
        var result = 0
        for byte in bytes[start..<(start + length)] {
            guard byte >= 48, byte <= 57 else { return nil }
            result = result * 10 + Int(byte - 48)
        }
        return result
    }
}

private func claudeStopReason(_ event: [String: Any]) -> String {
    guard let message = event["message"] as? [String: Any] else { return "" }
    return message["stop_reason"] as? String ?? message["stopReason"] as? String ?? ""
}

private func claudeTurnComplete(_ event: [String: Any]) -> Bool {
    if claudeStopReason(event) == "end_turn" { return true }
    if let message = event["message"] as? [String: Any],
       ["turnComplete", "isComplete", "isFinal"].contains(where: { truthy(message[$0]) }) { return true }
    return ["turnComplete", "isComplete", "isFinal"].contains(where: { truthy(event[$0]) })
}

private func claudeHasError(_ event: [String: Any]) -> Bool {
    if truthy(event["isApiErrorMessage"]) || event["apiErrorStatus"] != nil || event["error"] != nil { return true }
    guard let message = event["message"] as? [String: Any] else { return false }
    return truthy(message["isApiErrorMessage"]) || message["apiErrorStatus"] != nil || message["error"] != nil
}

private func claudeMessage(_ event: [String: Any]) -> String {
    if let message = event["message"] as? String { return message }
    if let message = event["message"] as? [String: Any] {
        for key in ["text", "message", "error", "content"] {
            if let value = message[key] as? String, !value.isEmpty { return value }
        }
        if let content = message["content"] as? [[String: Any]] {
            return content.compactMap { $0["text"] as? String }.joined(separator: " ")
        }
    }
    return event["error"] as? String ?? event["text"] as? String ?? ""
}

private func claudeEventID(_ prefix: String, event: [String: Any], timestamp: Date) -> String {
    let message = event["message"] as? [String: Any]
    for value in [event["uuid"], event["messageUuid"], event["message_id"], message?["uuid"], message?["id"]] {
        if let value = value as? String, !value.isEmpty { return "evt_\(prefix)_\(value)" }
    }
    if let sessionID = event["sessionId"] as? String, !sessionID.isEmpty {
        return "evt_\(prefix)_\(sessionID)_\(Int(timestamp.timeIntervalSince1970))"
    }
    return "evt_\(prefix)_\(Int(timestamp.timeIntervalSince1970))"
}

private func truthy(_ value: Any?) -> Bool {
    if let value = value as? Bool { return value }
    return (value as? String)?.lowercased() == "true"
}
