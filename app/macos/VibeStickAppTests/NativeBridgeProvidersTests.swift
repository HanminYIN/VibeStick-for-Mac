import Foundation
import Testing

@Suite("Native Swift Bridge provider observations")
struct NativeBridgeProvidersTests {
    private let now = Date(timeIntervalSince1970: 1_787_080_000)

    @Test("Codex new activity after completion reports running without stale alert")
    func codexNewActivity() {
        let observation = NativeProviderObservationEngine.observeCodex(
            sessions: [codexSession("root", user: true, events: [
                codexEvent(secondsAgo: 120, type: "task_complete", turn: "turn-1"),
                codexEvent(secondsAgo: 10, type: "custom_tool_call", turn: "turn-1"),
            ])],
            online: true,
            fallbackProject: "VibeStick",
            now: now
        )
        #expect(observation.status == "RUNNING")
        #expect(observation.alertType == "NONE")
    }

    @Test("Codex latest completion is stable and subagent completion is ignored")
    func codexCompletionAndSubagentIsolation() {
        let root = codexSession("root", user: true, events: [
            codexEvent(secondsAgo: 30, type: "task_started", turn: "main"),
            codexEvent(secondsAgo: 5, type: "task_complete", turn: "main"),
        ])
        let subagent = codexSession("sub", user: false, events: [
            codexEvent(secondsAgo: 2, type: "task_complete", turn: "review"),
        ])
        let result = NativeProviderObservationEngine.observeCodex(
            sessions: [root, subagent], online: true, fallbackProject: "VibeStick", now: now
        )
        #expect(result.status == "DONE")
        #expect(result.alertType == "DONE")
        #expect(result.alertMessage == "Codex task completed")
        #expect(result.alertEventID.hasSuffix("_done"))
    }

    @Test("running Codex project outranks a more recent completed project")
    func codexProjectSelection() {
        let running = codexSession("a", user: true, cwd: "/workspace/M5StickS3", events: [
            codexEvent(secondsAgo: 20, type: "task_started", turn: "a"),
        ])
        let complete = codexSession("b", user: true, cwd: "/workspace/VPS", events: [
            codexEvent(secondsAgo: 10, type: "task_started", turn: "b"),
            codexEvent(secondsAgo: 5, type: "task_complete", turn: "b"),
        ])
        let result = NativeProviderObservationEngine.observeCodex(
            sessions: [running, complete], online: true, fallbackProject: "fallback", now: now
        )
        #expect(result.status == "RUNNING")
        #expect(result.project == "M5StickS3")
    }

    @Test("account-wide quota outranks newer named-model quota including internal sessions")
    func codexAccountQuotaPriority() {
        let main = codexSession("main", user: true, events: [
            codexEvent(secondsAgo: 10, type: "task_started", turn: "main"),
            quotaEvent(secondsAgo: 5, used: 0, limitID: "codex_model"),
        ])
        let internalQuota = codexSession("internal", user: false, events: [
            quotaEvent(secondsAgo: 20, used: 4, limitID: "codex"),
        ])
        let result = NativeProviderObservationEngine.observeCodex(
            sessions: [main, internalQuota], online: true, fallbackProject: "VibeStick", now: now
        )
        #expect(result.status == "RUNNING")
        #expect(result.quota.quota7DRemaining == 96)
        #expect(result.quota.quotaSource == "codex-session-log")
    }

    @Test("Claude default-mode tool use asks approval while auto mode keeps running")
    func claudeApprovalModes() {
        func result(mode: String) -> NativeProviderObservation {
            NativeProviderObservationEngine.observeClaude(events: [
                claudeEvent(secondsAgo: 120, type: "user", session: "s1", extra: ["permissionMode": mode]),
                claudeEvent(secondsAgo: 60, type: "assistant", session: "s1", extra: [
                    "message": ["id": "msg_tool", "stop_reason": "tool_use", "content": []],
                ]),
            ], online: true, project: "VibeStick", now: now)
        }
        #expect(result(mode: "default").status == "APPROVAL")
        #expect(result(mode: "default").alertEventID == "evt_claude_approval_msg_tool")
        #expect(result(mode: "acceptEdits").status == "RUNNING")
        #expect(result(mode: "acceptEdits").alertType == "NONE")
    }

    @Test("Claude end turn reports done but newer activity resumes running")
    func claudeCompletionLifecycle() {
        let done = claudeEvent(secondsAgo: 120, type: "assistant", session: "s1", extra: [
            "message": ["id": "msg_done", "stop_reason": "end_turn", "content": []],
        ])
        let completed = NativeProviderObservationEngine.observeClaude(
            events: [done], online: true, project: "VibeStick", now: now
        )
        let resumed = NativeProviderObservationEngine.observeClaude(
            events: [done, claudeEvent(secondsAgo: 10, type: "user", session: "s1")],
            online: true, project: "VibeStick", now: now
        )
        #expect(completed.status == "DONE")
        #expect(completed.alertEventID == "evt_claude_done_msg_done")
        #expect(resumed.status == "RUNNING")
        #expect(resumed.alertType == "NONE")
    }

    @Test("process matching stays narrow")
    func processMatching() {
        #expect(NativeProviderObservationEngine.codexProcessRunning(commands: [
            "/Applications/ChatGPT.app/Contents/Resources/codex -c feature=x app-server",
        ]))
        #expect(!NativeProviderObservationEngine.codexProcessRunning(commands: [
            "/Applications/ChatGPT.app/Contents/Frameworks/Codex Renderer",
        ]))
        #expect(NativeProviderObservationEngine.claudeProcessRunning(commands: ["/usr/local/bin/claude"]))
        #expect(!NativeProviderObservationEngine.claudeProcessRunning(commands: [
            "/usr/bin/node /tmp/claude-hud/index.js",
        ]))
    }

    @Test("auto provider follows sole online provider then newest activity")
    func providerSelection() {
        let codex = observation(id: "codex", online: true, timestamp: now.addingTimeInterval(-20))
        let offlineClaude = observation(id: "claude", online: false, timestamp: nil)
        let activeClaude = observation(id: "claude", online: true, timestamp: now.addingTimeInterval(-10))
        #expect(NativeProviderObservationEngine.selectActiveProvider(
            configured: "auto", lastActive: "claude", codex: codex, claude: offlineClaude
        ) == "codex")
        #expect(NativeProviderObservationEngine.selectActiveProvider(
            configured: "auto", lastActive: "codex", codex: codex, claude: activeClaude
        ) == "claude")
    }

    @Test("unchanged Codex session files reuse their parsed input")
    func unchangedSessionsAreCached() throws {
        try withProviderTemporaryDirectory { directory in
            try writeCodexSession(id: "cached-session", source: "cli", to: directory)
            let reads = ProviderFileReadCounter()
            let source = NativeProviderFileSource(
                readPrefix: { url, maximumBytes in
                    reads.notePrefix()
                    return try NativeBridgeSecureFile.readPrefix(at: url, maximumBytes: maximumBytes)
                },
                readTail: { url, maximumBytes in
                    reads.noteTail()
                    return try NativeBridgeSecureFile.readTail(at: url, maximumBytes: maximumBytes)
                }
            )

            let first = source.codexObservation(
                root: directory,
                online: true,
                fallbackProject: "VibeStick",
                now: now
            )
            let second = source.codexObservation(
                root: directory,
                online: true,
                fallbackProject: "VibeStick",
                now: now
            )
            #expect(first.status == "RUNNING")
            #expect(second.status == "RUNNING")
            #expect(reads.prefixCount == 1)
            #expect(reads.tailCount == 1)
        }
    }

    @Test("an appended Codex session invalidates its cached input")
    func changedSessionInvalidatesCache() throws {
        try withProviderTemporaryDirectory { directory in
            let id = "changing-session"
            try writeCodexSession(id: id, source: "cli", to: directory)
            let reads = ProviderFileReadCounter()
            let source = NativeProviderFileSource(
                readPrefix: { url, maximumBytes in
                    reads.notePrefix()
                    return try NativeBridgeSecureFile.readPrefix(at: url, maximumBytes: maximumBytes)
                },
                readTail: { url, maximumBytes in
                    reads.noteTail()
                    return try NativeBridgeSecureFile.readTail(at: url, maximumBytes: maximumBytes)
                }
            )

            let first = source.codexObservation(
                root: directory,
                online: true,
                fallbackProject: "VibeStick",
                now: now
            )
            #expect(first.status == "RUNNING")
            try appendCodexEvent(id: id, to: directory)
            let second = source.codexObservation(
                root: directory,
                online: true,
                fallbackProject: "VibeStick",
                now: now
            )

            #expect(second.status == "DONE")
            #expect(reads.prefixCount == 2)
            #expect(reads.tailCount == 2)
        }
    }

    @Test("Codex category limits are applied before reading event tails")
    func categoryLimitsBoundTailReads() throws {
        try withProviderTemporaryDirectory { directory in
            for index in 0..<12 {
                try writeCodexSession(id: "unknown-\(index)", source: nil, to: directory)
            }
            let reads = ProviderFileReadCounter()
            let source = NativeProviderFileSource(
                readPrefix: { url, maximumBytes in
                    reads.notePrefix()
                    return try NativeBridgeSecureFile.readPrefix(at: url, maximumBytes: maximumBytes)
                },
                readTail: { url, maximumBytes in
                    reads.noteTail()
                    return try NativeBridgeSecureFile.readTail(at: url, maximumBytes: maximumBytes)
                }
            )

            _ = source.codexObservation(
                root: directory,
                online: true,
                fallbackProject: "VibeStick",
                now: now
            )
            #expect(reads.prefixCount == 12)
            #expect(reads.tailCount == 10)
        }
    }

    @Test("unchanged Claude session files reuse their compact observation")
    func unchangedClaudeSessionsAreCached() throws {
        try withProviderTemporaryDirectory { directory in
            try writeClaudeSession(to: directory)
            let reads = ProviderFileReadCounter()
            let source = NativeProviderFileSource(
                readTail: { url, maximumBytes in
                    reads.noteTail()
                    return try NativeBridgeSecureFile.readTail(at: url, maximumBytes: maximumBytes)
                }
            )

            let first = source.claudeObservation(
                root: directory,
                online: true,
                project: "VibeStick",
                now: now
            )
            let second = source.claudeObservation(
                root: directory,
                online: true,
                project: "VibeStick",
                now: now
            )

            #expect(first.status == "RUNNING")
            #expect(second.status == "RUNNING")
            #expect(reads.tailCount == 1)
        }
    }

    private func codexSession(
        _ id: String,
        user: Bool?,
        cwd: String? = "/workspace/VibeStick",
        events: [[String: Any]]
    ) -> NativeCodexSessionInput {
        .init(sessionID: id, userInitiated: user, metadataWorkingDirectory: cwd, events: events)
    }

    private func codexEvent(secondsAgo: TimeInterval, type: String, turn: String) -> [String: Any] {
        [
            "timestamp": timestamp(secondsAgo),
            "type": "event_msg",
            "payload": ["type": type, "turn_id": turn],
        ]
    }

    private func quotaEvent(secondsAgo: TimeInterval, used: Double, limitID: String) -> [String: Any] {
        [
            "timestamp": timestamp(secondsAgo),
            "type": "event_msg",
            "payload": [
                "type": "token_count",
                "rate_limits": [
                    "limit_id": limitID,
                    "primary": ["used_percent": used, "window_minutes": 10_080],
                ],
            ],
        ]
    }

    private func claudeEvent(
        secondsAgo: TimeInterval,
        type: String,
        session: String,
        extra: [String: Any] = [:]
    ) -> [String: Any] {
        var result: [String: Any] = [
            "timestamp": timestamp(secondsAgo),
            "type": type,
            "sessionId": session,
        ]
        for (key, value) in extra { result[key] = value }
        return result
    }

    private func timestamp(_ secondsAgo: TimeInterval) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .nanosecond],
            from: now.addingTimeInterval(-secondsAgo)
        )
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0,
            components.hour ?? 0,
            components.minute ?? 0,
            components.second ?? 0,
            (components.nanosecond ?? 0) / 1_000_000
        )
    }

    private func observation(id: String, online: Bool, timestamp: Date?) -> NativeProviderObservation {
        .init(
            providerID: id,
            displayName: id.capitalized,
            online: online,
            status: online ? "IDLE" : "OFFLINE",
            project: "VibeStick",
            quota: .init(),
            alertType: "NONE",
            alertMessage: "",
            alertEventID: "",
            latestEventTimestamp: timestamp
        )
    }
}

private final class ProviderFileReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var prefixes = 0
    private var tails = 0

    var prefixCount: Int { lock.withLock { prefixes } }
    var tailCount: Int { lock.withLock { tails } }

    func notePrefix() { lock.withLock { prefixes += 1 } }
    func noteTail() { lock.withLock { tails += 1 } }
}

private func withProviderTemporaryDirectory(_ operation: (URL) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "vibestick-provider-tests-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try operation(directory)
}

private func writeCodexSession(id: String, source: String?, to directory: URL) throws {
    var payload: [String: Any] = ["id": id, "cwd": "/workspace/VibeStick"]
    if let source { payload["source"] = source }
    let metadata: [String: Any] = ["type": "session_meta", "payload": payload]
    let event: [String: Any] = [
        "timestamp": "2026-08-20T12:00:00.000Z",
        "type": "event_msg",
        "payload": ["type": "task_started", "turn_id": "turn-1"],
    ]
    let lines = try [metadata, event].map {
        String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self)
    }.joined(separator: "\n") + "\n"
    try Data(lines.utf8).write(
        to: directory.appendingPathComponent("rollout-\(id).jsonl"),
        options: .atomic
    )
}

private func appendCodexEvent(id: String, to directory: URL) throws {
    let event: [String: Any] = [
        "timestamp": "2026-08-20T12:00:01.000Z",
        "type": "event_msg",
        "payload": ["type": "task_complete", "turn_id": "turn-1"],
    ]
    var data = try JSONSerialization.data(withJSONObject: event)
    data.append(0x0A)
    let path = directory.appendingPathComponent("rollout-\(id).jsonl")
    let handle = try FileHandle(forWritingTo: path)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: data)
}

private func writeClaudeSession(to directory: URL) throws {
    let event: [String: Any] = [
        "timestamp": "2026-08-20T12:00:00.000Z",
        "type": "user",
        "sessionId": "claude-session",
    ]
    var data = try JSONSerialization.data(withJSONObject: event)
    data.append(0x0A)
    try data.write(
        to: directory.appendingPathComponent("claude-session.jsonl"),
        options: .atomic
    )
}
