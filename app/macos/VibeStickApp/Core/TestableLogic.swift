import Foundation

enum ASRTestTranscriptComparator {
    static func normalized(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
            .lowercased()
    }

    static func matches(expected: String, actual: String) -> Bool {
        let expected = normalized(expected)
        let actual = normalized(actual)
        return !expected.isEmpty && (actual == expected || actual.contains(expected))
    }
}

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
                "-W",
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

    static func unregisterCommand(appPath: String) -> PastePermissionProbeCommand {
        PastePermissionProbeCommand(
            executable: "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
            arguments: ["-u", appPath]
        )
    }

    static func permission(from data: Data) -> Bool? {
        try? JSONDecoder().decode(PastePermissionProbeResponse.self, from: data).success
    }
}

enum USBDeviceDetectionParser {
    static func detect(ioregOutput: String, ports: [String]) -> USBDeviceCandidate? {
        let availablePorts = Set(ports.filter { $0.hasPrefix("/dev/cu.usbmodem") })
        var candidates: [USBDeviceCandidate] = []
        for rawBlock in ioregOutput.components(separatedBy: "+-o AppleUSBACMData").dropFirst() {
            guard rawBlock.contains("\"idVendor\" = 12346"),
                  rawBlock.contains("\"idProduct\" = 4097"),
                  let suffix = quotedValue(after: "IOTTYSuffix", in: rawBlock) else {
                continue
            }
            let port = "/dev/cu.usbmodem\(suffix)"
            guard availablePorts.contains(port) else { continue }
            candidates.append(
                USBDeviceCandidate(
                    portPath: port,
                    serialNumber: quotedValue(after: "USB Serial Number", in: rawBlock),
                    vendorID: USBDeviceCandidate.esp32S3VendorID,
                    productID: USBDeviceCandidate.usbSerialJTAGProductID
                )
            )
        }
        return candidates.sorted { $0.portPath < $1.portPath }.first
    }

    private static func quotedValue(after key: String, in text: String) -> String? {
        for line in text.split(whereSeparator: \Character.isNewline) where line.contains(key) {
            guard let equals = line.firstIndex(of: "=") else { continue }
            let value = line[line.index(after: equals)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if !value.isEmpty { return value }
        }
        return nil
    }
}

enum SerialResponseParser {
    private static let marker = Data("VIBESTICK_RESPONSE ".utf8)

    static func responsePayload(in data: Data) -> Data? {
        guard let markerRange = data.range(of: marker) else { return nil }
        let start = markerRange.upperBound
        let suffix = data[start...]
        guard let newline = suffix.firstIndex(of: 0x0A) else { return nil }
        let payload = Data(suffix[..<newline])
        guard !payload.isEmpty, payload.count <= 4096 else { return nil }
        return payload
    }
}

enum ManualBridgeAddressValidator {
    static func normalized(_ value: String?) throws -> String? {
        guard let value else { return nil }
        let candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return nil }
        guard candidate.count <= 253,
              !candidate.contains(":"),
              !candidate.contains("/"),
              !candidate.contains(" "),
              candidate.lowercased() != "localhost",
              candidate != "0.0.0.0" else {
            throw ManualBridgeAddressError.invalid
        }
        if isIPv4(candidate) { return candidate }

        let labels = candidate.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty, labels.allSatisfy({ label in
            guard !label.isEmpty, label.count <= 63,
                  label.first?.isLetter == true || label.first?.isNumber == true,
                  label.last?.isLetter == true || label.last?.isNumber == true else {
                return false
            }
            return label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        }) else {
            throw ManualBridgeAddressError.invalid
        }
        return candidate.lowercased()
    }

    static func isIPv4(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard !part.isEmpty, part.count <= 3, part.allSatisfy(\.isNumber),
                  let number = Int(part), (0...255).contains(number) else {
                return false
            }
            return String(number) == part || part == "0"
        }
    }
}

enum ManualBridgeAddressError: LocalizedError {
    case invalid

    var errorDescription: String? {
        "手动 Bridge 地址无效；请填写 IPv4 地址或局域网主机名"
    }
}
