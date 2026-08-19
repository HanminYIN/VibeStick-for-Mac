import Darwin
import Foundation

enum NativeCodexRateLimitParser {
    static func snapshot(
        from result: Any,
        observedAt: Date = Date(),
        calendar: Calendar = .current
    ) -> NativeQuotaSnapshot? {
        guard let result = result as? [String: Any] else { return nil }
        var limits: [String: Any]?
        if let byID = result["rateLimitsByLimitId"] as? [String: Any] {
            limits = byID["codex"] as? [String: Any]
        }
        if limits == nil,
           let historical = result["rateLimits"] as? [String: Any],
           ((historical["limitId"] as? String) ?? "codex")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "codex" {
            limits = historical
        }
        guard let limits else { return nil }

        var fiveHour: Int?
        var sevenDay: Int?
        for key in ["primary", "secondary"] {
            guard let window = limits[key] as? [String: Any],
                  let used = percent(window["usedPercent"]),
                  let duration = integer(window["windowDurationMins"]) else { continue }
            let remaining = min(100, max(0, 100 - used))
            if duration == 300 { fiveHour = remaining }
            if duration == 10_080 { sevenDay = remaining }
        }
        guard fiveHour != nil || sevenDay != nil else { return nil }
        let components = calendar.dateComponents([.hour, .minute], from: observedAt)
        return NativeQuotaSnapshot(
            quota5HRemaining: fiveHour,
            quota7DRemaining: sevenDay,
            quotaUpdatedAt: String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0),
            quotaStale: false,
            quotaSource: "codex-app-server",
            quotaObservedAtEpoch: observedAt.timeIntervalSince1970
        )
    }

    private static func percent(_ raw: Any?) -> Int? {
        guard let number = raw as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else { return nil }
        return min(100, max(0, Int(number.doubleValue)))
    }

    private static func integer(_ raw: Any?) -> Int? {
        guard let number = raw as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite,
              number.doubleValue.rounded() == number.doubleValue else { return nil }
        return number.intValue
    }
}

protocol NativeCodexQuotaTransport: AnyObject {
    func fetchRateLimits(executable: URL, timeout: TimeInterval) -> Any?
}

final class NativeCodexAppServerTransport: NativeCodexQuotaTransport {
    static let maximumResponseBytes = 1_048_576

    func fetchRateLimits(executable: URL, timeout: TimeInterval) -> Any? {
        guard executable.isFileURL,
              FileManager.default.isExecutableFile(atPath: executable.path) else { return nil }
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        defer { stop(process) }

        let deadline = Date().timeIntervalSince1970 + max(1, min(30, timeout))
        var buffer = Data()
        guard send([
            "method": "initialize",
            "id": 1,
            "params": [
                "clientInfo": ["name": "vibestick-bridge", "version": "0.2.0"],
                "capabilities": ["experimentalApi": true],
            ],
        ], to: input.fileHandleForWriting),
        let initialized = response(
            id: 1,
            from: output.fileHandleForReading,
            deadline: deadline,
            buffer: &buffer
        ), initialized["error"] == nil,
        send(["method": "initialized", "params": [:]], to: input.fileHandleForWriting),
        send([
            "method": "account/rateLimits/read",
            "id": 2,
            "params": NSNull(),
        ], to: input.fileHandleForWriting),
        let response = response(
            id: 2,
            from: output.fileHandleForReading,
            deadline: deadline,
            buffer: &buffer
        ), response["error"] == nil else {
            return nil
        }
        return response["result"]
    }

    private func send(_ object: [String: Any], to handle: FileHandle) -> Bool {
        guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return false
        }
        data.append(0x0A)
        do {
            try handle.write(contentsOf: data)
            return true
        } catch {
            return false
        }
    }

    private func response(
        id: Int,
        from handle: FileHandle,
        deadline: TimeInterval,
        buffer: inout Data
    ) -> [String: Any]? {
        let descriptor = handle.fileDescriptor
        while Date().timeIntervalSince1970 < deadline {
            while let lineEnd = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<lineEnd])
                buffer.removeSubrange(...lineEnd)
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    continue
                }
                if let responseID = object["id"] as? NSNumber,
                   CFGetTypeID(responseID) != CFBooleanGetTypeID(),
                   responseID.intValue == id {
                    return object
                }
            }
            let remaining = max(0, deadline - Date().timeIntervalSince1970)
            var item = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
            let milliseconds = Int32(min(1_000, max(1, Int(remaining * 1_000))))
            let ready = Darwin.poll(&item, 1, milliseconds)
            if ready < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if ready == 0 { continue }
            var bytes = [UInt8](repeating: 0, count: 8_192)
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                return nil
            }
            if count == 0 { return nil }
            guard buffer.count + count <= Self.maximumResponseBytes else { return nil }
            buffer.append(bytes, count: count)
        }
        return nil
    }

    private func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning && Date() < deadline { usleep(10_000) }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            let killDeadline = Date().addingTimeInterval(2)
            while process.isRunning && Date() < killDeadline { usleep(10_000) }
        }
    }
}

final class NativeCodexQuotaClient {
    private let transport: NativeCodexQuotaTransport
    private let resolveExecutable: () -> URL?
    private let now: () -> Date
    private let timeout: TimeInterval

    init(
        transport: NativeCodexQuotaTransport = NativeCodexAppServerTransport(),
        resolveExecutable: @escaping () -> URL? = NativeCodexQuotaClient.defaultExecutable,
        now: @escaping () -> Date = Date.init,
        timeout: TimeInterval = 15
    ) {
        self.transport = transport
        self.resolveExecutable = resolveExecutable
        self.now = now
        self.timeout = max(1, min(30, timeout))
    }

    func fetch() -> NativeQuotaSnapshot? {
        guard let executable = resolveExecutable(),
              let result = transport.fetchRateLimits(executable: executable, timeout: timeout) else {
            return nil
        }
        return NativeCodexRateLimitParser.snapshot(from: result, observedAt: now())
    }

    static func defaultExecutable() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        var candidates: [String] = []
        if let configured = environment["VIBE_STICK_CODEX_CLI"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !configured.isEmpty {
            candidates.append((configured as NSString).expandingTildeInPath)
        }
        candidates += [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
        ]
        if let path = environment["PATH"] {
            candidates += path.split(separator: ":").map {
                URL(fileURLWithPath: String($0), isDirectory: true)
                    .appendingPathComponent("codex").path
            }
        }
        return candidates.lazy.compactMap { path -> URL? in
            guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { return nil }
            return URL(fileURLWithPath: path)
        }.first
    }
}
