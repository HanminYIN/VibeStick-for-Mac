import Foundation

enum LegacyEnvironmentParser {
    static func parse(_ contents: String) -> [String: String] {
        var values: [String: String] = [:]
        for rawLine in contents.split(whereSeparator: \Character.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if line.hasPrefix("export ") {
                line.removeFirst("export ".count)
            }
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }

            if value.count >= 2,
               let first = value.first,
               let last = value.last,
               (first == "\"" || first == "'"),
               first == last {
                value.removeFirst()
                value.removeLast()
            }
            values[key] = value
        }
        return values
    }
}

enum ServiceStateResolver {
    static func launchAgent(
        kind: ComponentKind,
        installed: Bool,
        loaded: Bool,
        running: Bool,
        ready: Bool?,
        detail: String? = nil
    ) -> ComponentHealth {
        guard installed else {
            return ComponentHealth(
                kind: kind,
                phase: .notInstalled,
                detail: "未找到现有安装",
                isInstalled: false,
                ownership: .none
            )
        }
        guard loaded else {
            return ComponentHealth(
                kind: kind,
                phase: .stopped,
                detail: "已安装，但当前没有运行",
                isInstalled: true
            )
        }
        guard running else {
            return ComponentHealth(
                kind: kind,
                phase: .needsRepair,
                detail: detail ?? "后台任务已载入，但进程当前没有运行",
                isInstalled: true
            )
        }
        if ready == false {
            return ComponentHealth(
                kind: kind,
                phase: .runningNotReady,
                detail: detail ?? "进程已运行，但服务尚未就绪",
                isInstalled: true
            )
        }
        return ComponentHealth(
            kind: kind,
            phase: .healthy,
            detail: detail ?? "运行正常",
            isInstalled: true
        )
    }
}

enum LaunchAgentStateParser {
    static func isRunning(_ launchctlOutput: String) -> Bool {
        launchctlOutput
            .split(whereSeparator: \Character.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .contains("state = running")
    }

    static func programPath(_ launchctlOutput: String) -> String? {
        for rawLine in launchctlOutput.split(whereSeparator: \Character.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let prefix = "program = "
            if line.hasPrefix(prefix) {
                let path = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
                return path.isEmpty ? nil : path
            }
        }
        return nil
    }
}

enum RecordingActivityResolver {
    static func shouldProtect(
        claimsActive: Bool,
        modifiedAt: Date?,
        bridgeProcessRunning: Bool,
        now: Date = Date(),
        maximumAge: TimeInterval = 10 * 60
    ) -> Bool {
        guard claimsActive,
              bridgeProcessRunning,
              let modifiedAt else {
            return false
        }
        let age = now.timeIntervalSince(modifiedAt)
        return age >= 0 && age < maximumAge
    }
}

struct PastePermissionProbeResponse: Decodable, Equatable {
    let success: Bool
    let message: String
}

struct PastePermissionProbeCommand: Equatable {
    let executable: String
    let arguments: [String]
}

enum PastePermissionProbeProtocol {
    static func launchCommand(
        appPath: String,
        requestPath: String,
        responsePath: String
    ) -> PastePermissionProbeCommand {
        PastePermissionProbeCommand(
            executable: "/usr/bin/open",
            arguments: [
                "-g",
                "-n",
                appPath,
                "--args",
                "--request",
                requestPath,
                "--response",
                responsePath,
            ]
        )
    }

    static func permission(from data: Data) -> Bool? {
        try? JSONDecoder().decode(PastePermissionProbeResponse.self, from: data).success
    }
}
