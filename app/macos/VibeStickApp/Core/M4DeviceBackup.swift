import CryptoKit
import Darwin
import Dispatch
import Foundation

struct DeviceBackupDescriptor: Equatable, Sendable {
    static let current = DeviceBackupDescriptor(
        schemaVersion: 1,
        expectedChip: "ESP32-S3",
        expectedFlashSizeLabel: "8MB",
        flashSizeBytes: 8 * 1024 * 1024,
        baudRate: 115_200,
        toolVersion: "5.3.1"
    )

    let schemaVersion: Int
    let expectedChip: String
    let expectedFlashSizeLabel: String
    let flashSizeBytes: UInt64
    let baudRate: Int
    let toolVersion: String

    func validate() throws {
        guard schemaVersion == 1,
              expectedChip == "ESP32-S3",
              expectedFlashSizeLabel == "8MB",
              flashSizeBytes == 8 * 1024 * 1024,
              baudRate == 115_200,
              toolVersion == FlashingToolDescriptor.current.version else {
            throw DeviceBackupError.invalidDescriptor
        }
    }
}

struct DeviceSecurityInspection: Codable, Equatable, Sendable {
    let chip: String
    let flashSizeLabel: String
    let flashSizeBytes: UInt64
    let flashManufacturerID: String
    let flashDeviceID: String
    let secureBootEnabled: Bool
    let flashEncryptionEnabled: Bool
    let deviceFingerprint: String
    let inspectedAt: String
    let toolVersion: String

    var shortFingerprint: String {
        String(deviceFingerprint.prefix(12))
    }
}

struct DeviceBackupReceipt: Equatable, Sendable {
    let backupDirectory: URL
    let flashImageURL: URL
    let receiptURL: URL
    let flashSHA256: String
    let inspection: DeviceSecurityInspection
}

enum DeviceBackupPhase: Equatable, Sendable {
    case idle
    case inspecting
    case downloadModeRequired
    case ready
    case backingUp
    case complete
    case blocked
    case failed
}

struct DeviceBackupSnapshot: Equatable, Sendable {
    let phase: DeviceBackupPhase
    let detail: String
    let inspection: DeviceSecurityInspection?
    let receipt: DeviceBackupReceipt?

    static let idle = DeviceBackupSnapshot(
        phase: .idle,
        detail: "尚未打开设备串口。检查和备份都需要单独确认。",
        inspection: nil,
        receipt: nil
    )

    static let inspecting = DeviceBackupSnapshot(
        phase: .inspecting,
        detail: "正在通过 ROM bootloader 读取设备身份、Flash 容量和安全状态。",
        inspection: nil,
        receipt: nil
    )

    static let backingUp = DeviceBackupSnapshot(
        phase: .backingUp,
        detail: "正在两次读取完整 8 MiB Flash 并比较 SHA-256。",
        inspection: nil,
        receipt: nil
    )

    static func ready(_ inspection: DeviceSecurityInspection) -> Self {
        Self(
            phase: .ready,
            detail: "已确认 ESP32-S3、8 MiB Flash，且 Secure Boot 与 Flash Encryption 均未启用。",
            inspection: inspection,
            receipt: nil
        )
    }

    static func complete(_ receipt: DeviceBackupReceipt) -> Self {
        Self(
            phase: .complete,
            detail: "两次完整读取一致；私有 8 MiB 备份和脱敏回执已保存。",
            inspection: receipt.inspection,
            receipt: receipt
        )
    }

    static func failure(_ error: Error, preserving inspection: DeviceSecurityInspection? = nil) -> Self {
        let backupError = error as? DeviceBackupError
        let phase: DeviceBackupPhase
        switch backupError {
        case .downloadModeRequired:
            phase = .downloadModeRequired
        case .secureBootEnabled, .flashEncryptionEnabled, .secureDownloadMode, .wrongChip, .wrongFlashSize,
             .identityChanged, .multipleDevices, .unsupportedUSBDevice:
            phase = .blocked
        default:
            phase = .failed
        }
        return Self(
            phase: phase,
            detail: error.localizedDescription,
            inspection: inspection,
            receipt: nil
        )
    }
}

struct DeviceToolResult: Equatable, Sendable {
    let standardOutput: String
    let standardError: String
}

protocol DeviceToolRunning: Sendable {
    func run(
        executableURL: URL,
        arguments: [String],
        workingDirectory: URL,
        timeout: TimeInterval
    ) throws -> DeviceToolResult
}

struct SystemDeviceToolRunner: DeviceToolRunning {
    func run(
        executableURL: URL,
        arguments: [String],
        workingDirectory: URL,
        timeout: TimeInterval
    ) throws -> DeviceToolResult {
        let process = Process()
        let output = Pipe()
        let errorOutput = Pipe()
        let completion = DispatchSemaphore(value: 0)
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errorOutput
        process.environment = [
            "LC_ALL": "C",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": workingDirectory.path,
            "ESPTOOL_CFGFILE": workingDirectory.appendingPathComponent("esptool.cfg").path,
        ]
        process.terminationHandler = { _ in completion.signal() }

        do {
            try process.run()
        } catch {
            throw DeviceBackupError.toolLaunchFailed
        }
        if completion.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if completion.wait(timeout: .now() + 2) == .timedOut {
                Darwin.kill(process.processIdentifier, SIGKILL)
                _ = completion.wait(timeout: .now() + 2)
            }
            throw DeviceBackupError.toolTimedOut
        }

        let standardOutputData = output.fileHandleForReading.readDataToEndOfFile()
        let standardErrorData = errorOutput.fileHandleForReading.readDataToEndOfFile()
        guard let standardOutput = String(data: standardOutputData, encoding: .utf8),
              let standardError = String(data: standardErrorData, encoding: .utf8) else {
            throw DeviceBackupError.invalidToolOutput
        }
        guard process.terminationStatus == 0 else {
            let combined = standardOutput + "\n" + standardError
            if combined.localizedCaseInsensitiveContains("No serial data received")
                || combined.localizedCaseInsensitiveContains("Failed to connect") {
                throw DeviceBackupError.downloadModeRequired
            }
            if combined.localizedCaseInsensitiveContains("Permission denied")
                || combined.localizedCaseInsensitiveContains("could not open")
                || combined.localizedCaseInsensitiveContains("resource busy") {
                throw DeviceBackupError.cannotOpenSerialPort
            }
            throw DeviceBackupError.toolFailed(exitCode: process.terminationStatus)
        }
        return DeviceToolResult(
            standardOutput: standardOutput,
            standardError: standardError
        )
    }
}

enum DeviceInspectionOutputParser {
    static func parse(
        securityOutput: String,
        flashOutput: String,
        macOutput: String,
        descriptor: DeviceBackupDescriptor,
        inspectedAt: String
    ) throws -> DeviceSecurityInspection {
        guard let chipDescription = capture(
            #"(?im)^Chip type:\s*([^\r\n]+)\s*$"#,
            in: securityOutput
        )?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw DeviceBackupError.wrongChip
        }
        if chipDescription == "ESP32-S3 in Secure Download Mode" {
            throw DeviceBackupError.secureDownloadMode
        }
        let supportedDescription = #"^(?:ESP32-S3 \(QFN56\)|ESP32-S3-PICO-1 \(LGA56\)|Unknown ESP32-S3) \(revision v[0-9]+\.[0-9]+\)$"#
        guard chipDescription.range(
            of: supportedDescription,
            options: .regularExpression
        ) != nil else {
            throw DeviceBackupError.wrongChip
        }
        guard securityOutput.contains("Security Information:") else {
            throw DeviceBackupError.invalidToolOutput
        }

        let secureBootEnabled: Bool
        if securityOutput.contains("Secure Boot: Disabled") {
            secureBootEnabled = false
        } else if securityOutput.contains("Secure Boot: Enabled") {
            secureBootEnabled = true
        } else {
            throw DeviceBackupError.invalidToolOutput
        }

        let flashEncryptionEnabled: Bool
        if securityOutput.contains("Flash Encryption: Disabled") {
            flashEncryptionEnabled = false
        } else if securityOutput.contains("Flash Encryption: Enabled") {
            flashEncryptionEnabled = true
        } else {
            throw DeviceBackupError.invalidToolOutput
        }
        if secureBootEnabled { throw DeviceBackupError.secureBootEnabled }
        if flashEncryptionEnabled { throw DeviceBackupError.flashEncryptionEnabled }

        guard let flashSize = capture(
            #"Detected flash size:\s*([^\r\n]+)"#,
            in: flashOutput
        )?.trimmingCharacters(in: .whitespacesAndNewlines),
              flashSize == descriptor.expectedFlashSizeLabel else {
            throw DeviceBackupError.wrongFlashSize
        }
        guard let manufacturer = capture(#"Manufacturer:\s*([0-9a-fA-F]{2})"#, in: flashOutput),
              let device = capture(#"Device:\s*([0-9a-fA-F]{4})"#, in: flashOutput) else {
            throw DeviceBackupError.invalidToolOutput
        }
        guard let rawMAC = capture(
            #"(?im)^MAC:\s*([0-9a-f]{2}(?::[0-9a-f]{2}){5})\s*$"#,
            in: macOutput
        )?.lowercased() else {
            throw DeviceBackupError.invalidToolOutput
        }

        var fingerprintInput = Data("vibestick-device-backup-v1\0".utf8)
        fingerprintInput.append(Data(rawMAC.utf8))
        let fingerprint = SHA256.hash(data: fingerprintInput)
            .map { String(format: "%02x", $0) }
            .joined()

        return DeviceSecurityInspection(
            chip: descriptor.expectedChip,
            flashSizeLabel: flashSize,
            flashSizeBytes: descriptor.flashSizeBytes,
            flashManufacturerID: manufacturer.lowercased(),
            flashDeviceID: device.lowercased(),
            secureBootEnabled: secureBootEnabled,
            flashEncryptionEnabled: flashEncryptionEnabled,
            deviceFingerprint: fingerprint,
            inspectedAt: inspectedAt,
            toolVersion: descriptor.toolVersion
        )
    }

    private static func capture(_ pattern: String, in value: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: value,
                range: NSRange(value.startIndex..., in: value)
              ),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: value) else {
            return nil
        }
        return String(value[range])
    }
}

private struct DeviceBackupReceiptDocument: Codable, Equatable {
    struct FlashImage: Codable, Equatable {
        let path: String
        let offset: String
        let size: UInt64
        let sha256: String
        let verification: String
    }

    let schemaVersion: Int
    let createdAt: String
    let tool: String
    let toolVersion: String
    let chip: String
    let flashSizeBytes: UInt64
    let flashManufacturerID: String
    let flashDeviceID: String
    let secureBootEnabled: Bool
    let flashEncryptionEnabled: Bool
    let deviceFingerprint: String
    let image: FlashImage

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case createdAt = "created_at"
        case tool
        case toolVersion = "tool_version"
        case chip
        case flashSizeBytes = "flash_size_bytes"
        case flashManufacturerID = "flash_manufacturer_id"
        case flashDeviceID = "flash_device_id"
        case secureBootEnabled = "secure_boot_enabled"
        case flashEncryptionEnabled = "flash_encryption_enabled"
        case deviceFingerprint = "device_fingerprint_sha256"
        case image
    }
}

actor DeviceBackupManager {
    private let descriptor: DeviceBackupDescriptor
    private let backupRoot: URL
    private let deviceDetector: any USBDeviceDetecting
    private let runner: any DeviceToolRunning
    private let fileManager: FileManager

    init(
        descriptor: DeviceBackupDescriptor = .current,
        backupRoot: URL = SupportPaths.supportDirectory
            .appendingPathComponent("FirmwareBackups.noindex", isDirectory: true),
        deviceDetector: any USBDeviceDetecting = USBDeviceDetector(),
        runner: any DeviceToolRunning = SystemDeviceToolRunner(),
        fileManager: FileManager = .default
    ) {
        self.descriptor = descriptor
        self.backupRoot = backupRoot
        self.deviceDetector = deviceDetector
        self.runner = runner
        self.fileManager = fileManager
    }

    func inspect(executableURL: URL) async throws -> DeviceSecurityInspection {
        try descriptor.validate()
        let candidate = try await uniqueCandidate()
        let workingDirectory = try makePrivateWorkingDirectory(prefix: ".Inspecting")
        defer { try? fileManager.removeItem(at: workingDirectory) }
        return try inspectConnectedDevice(
            candidate: candidate,
            executableURL: executableURL,
            workingDirectory: workingDirectory,
            resetAfterFinalCommand: true
        )
    }

    func createBackup(
        expectedInspection: DeviceSecurityInspection,
        executableURL: URL
    ) async throws -> DeviceBackupReceipt {
        try descriptor.validate()
        let candidate = try await uniqueCandidate()
        let stagingDirectory = try makePrivateWorkingDirectory(prefix: ".Backup")
        defer { try? fileManager.removeItem(at: stagingDirectory) }

        let currentInspection = try inspectConnectedDevice(
            candidate: candidate,
            executableURL: executableURL,
            workingDirectory: stagingDirectory,
            resetAfterFinalCommand: false
        )
        guard currentInspection.deviceFingerprint == expectedInspection.deviceFingerprint,
              currentInspection.flashManufacturerID == expectedInspection.flashManufacturerID,
              currentInspection.flashDeviceID == expectedInspection.flashDeviceID else {
            throw DeviceBackupError.identityChanged
        }

        let firstRead = stagingDirectory.appendingPathComponent("flash-8MiB.bin")
        let secondRead = stagingDirectory.appendingPathComponent(".flash-8MiB.verify.bin")
        try preparePrivateOutputFile(firstRead)
        try preparePrivateOutputFile(secondRead)

        _ = try runDeviceCommand(
            executableURL: executableURL,
            portPath: candidate.portPath,
            command: [
                "read-flash", "--flash-size", descriptor.expectedFlashSizeLabel,
                "--no-progress", "0x0", "0x800000", firstRead.path,
            ],
            resetAfterCommand: false,
            workingDirectory: stagingDirectory,
            timeout: 900
        )
        try validateReadFile(firstRead)
        let firstDigest = try RuntimePayloadDigest.sha256(of: firstRead)

        _ = try runDeviceCommand(
            executableURL: executableURL,
            portPath: candidate.portPath,
            command: [
                "read-flash", "--flash-size", descriptor.expectedFlashSizeLabel,
                "--no-progress", "0x0", "0x800000", secondRead.path,
            ],
            resetAfterCommand: true,
            workingDirectory: stagingDirectory,
            timeout: 900
        )
        try validateReadFile(secondRead)
        let secondDigest = try RuntimePayloadDigest.sha256(of: secondRead)
        guard firstDigest == secondDigest else {
            throw DeviceBackupError.doubleReadMismatch
        }
        try fileManager.removeItem(at: secondRead)
        try fileManager.removeItem(at: stagingDirectory.appendingPathComponent("esptool.cfg"))

        let createdAt = Self.timestamp()
        let receiptDocument = DeviceBackupReceiptDocument(
            schemaVersion: descriptor.schemaVersion,
            createdAt: createdAt,
            tool: "esptool",
            toolVersion: descriptor.toolVersion,
            chip: currentInspection.chip,
            flashSizeBytes: descriptor.flashSizeBytes,
            flashManufacturerID: currentInspection.flashManufacturerID,
            flashDeviceID: currentInspection.flashDeviceID,
            secureBootEnabled: currentInspection.secureBootEnabled,
            flashEncryptionEnabled: currentInspection.flashEncryptionEnabled,
            deviceFingerprint: currentInspection.deviceFingerprint,
            image: .init(
                path: firstRead.lastPathComponent,
                offset: "0x0",
                size: descriptor.flashSizeBytes,
                sha256: firstDigest,
                verification: "two-complete-reads-sha256-match"
            )
        )
        let receiptURL = stagingDirectory.appendingPathComponent("receipt-v1.json")
        try writePrivateJSON(receiptDocument, to: receiptURL)

        let finalName = "\(Self.fileTimestamp())-\(currentInspection.shortFingerprint)-\(UUID().uuidString.lowercased())"
        let finalDirectory = backupRoot.appendingPathComponent(finalName, isDirectory: true)
        try renameItem(at: stagingDirectory, to: finalDirectory)
        do {
            try validateFinalDirectory(
                finalDirectory,
                expectedDigest: firstDigest,
                expectedReceipt: receiptDocument
            )
        } catch {
            try? fileManager.removeItem(at: finalDirectory)
            throw error
        }

        return DeviceBackupReceipt(
            backupDirectory: finalDirectory,
            flashImageURL: finalDirectory.appendingPathComponent(firstRead.lastPathComponent),
            receiptURL: finalDirectory.appendingPathComponent(receiptURL.lastPathComponent),
            flashSHA256: firstDigest,
            inspection: currentInspection
        )
    }

    private func uniqueCandidate() async throws -> USBDeviceCandidate {
        let candidates = await deviceDetector.detectAll()
        guard !candidates.isEmpty else { throw DeviceBackupError.noDevice }
        guard candidates.count == 1 else { throw DeviceBackupError.multipleDevices }
        let candidate = candidates[0]
        guard candidate.vendorID == USBDeviceCandidate.esp32S3VendorID,
              candidate.productID == USBDeviceCandidate.usbSerialJTAGProductID,
              candidate.portPath.hasPrefix("/dev/cu.usbmodem"),
              !candidate.portPath.contains("..") else {
            throw DeviceBackupError.unsupportedUSBDevice
        }
        return candidate
    }

    private func inspectConnectedDevice(
        candidate: USBDeviceCandidate,
        executableURL: URL,
        workingDirectory: URL,
        resetAfterFinalCommand: Bool
    ) throws -> DeviceSecurityInspection {
        let security = try runDeviceCommand(
            executableURL: executableURL,
            portPath: candidate.portPath,
            command: ["get-security-info"],
            resetAfterCommand: false,
            workingDirectory: workingDirectory,
            timeout: 45
        )
        let flash = try runDeviceCommand(
            executableURL: executableURL,
            portPath: candidate.portPath,
            command: ["flash-id", "--spi-connection", "SPI"],
            resetAfterCommand: false,
            workingDirectory: workingDirectory,
            timeout: 45
        )
        let mac = try runDeviceCommand(
            executableURL: executableURL,
            portPath: candidate.portPath,
            command: ["read-mac"],
            resetAfterCommand: resetAfterFinalCommand,
            workingDirectory: workingDirectory,
            timeout: 45
        )
        return try DeviceInspectionOutputParser.parse(
            securityOutput: security.standardOutput + "\n" + security.standardError,
            flashOutput: flash.standardOutput + "\n" + flash.standardError,
            macOutput: mac.standardOutput + "\n" + mac.standardError,
            descriptor: descriptor,
            inspectedAt: Self.timestamp()
        )
    }

    private func runDeviceCommand(
        executableURL: URL,
        portPath: String,
        command: [String],
        resetAfterCommand: Bool,
        workingDirectory: URL,
        timeout: TimeInterval
    ) throws -> DeviceToolResult {
        guard executableURL.lastPathComponent == "esptool",
              !command.isEmpty,
              ["get-security-info", "flash-id", "read-mac", "read-flash"].contains(command[0]) else {
            throw DeviceBackupError.commandNotAllowed
        }
        let arguments = [
            "--chip", "esp32s3",
            "--port", portPath,
            "--baud", String(descriptor.baudRate),
            "--before", "no-reset",
            "--after", resetAfterCommand ? "watchdog-reset" : "no-reset",
            "--no-stub",
            "--connect-attempts", "3",
        ] + command
        return try runner.run(
            executableURL: executableURL,
            arguments: arguments,
            workingDirectory: workingDirectory,
            timeout: timeout
        )
    }

    private func makePrivateWorkingDirectory(prefix: String) throws -> URL {
        try prepareBackupRoot()
        let directory = backupRoot.appendingPathComponent(
            "\(prefix).partial-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let configURL = directory.appendingPathComponent("esptool.cfg")
            try Data("[esptool]\n".utf8).write(to: configURL, options: [.atomic])
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
            return directory
        } catch {
            try? fileManager.removeItem(at: directory)
            throw DeviceBackupError.fileFailure
        }
    }

    private func prepareBackupRoot() throws {
        do {
            try fileManager.createDirectory(
                at: backupRoot,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let values = try backupRoot.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw DeviceBackupError.fileFailure
            }
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: backupRoot.path)
        } catch let error as DeviceBackupError {
            throw error
        } catch {
            throw DeviceBackupError.fileFailure
        }
    }

    private func preparePrivateOutputFile(_ url: URL) throws {
        guard fileManager.createFile(
            atPath: url.path,
            contents: Data(),
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw DeviceBackupError.fileFailure
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func validateReadFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw DeviceBackupError.invalidBackupFile
        }
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let mode = (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
        guard size == descriptor.flashSizeBytes, mode == 0o600 else {
            throw DeviceBackupError.invalidBackupFile
        }
    }

    private func writePrivateJSON<Value: Encodable>(_ value: Value, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(value)
        data.append(0x0a)
        try data.write(to: url, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func validateFinalDirectory(
        _ directory: URL,
        expectedDigest: String,
        expectedReceipt: DeviceBackupReceiptDocument
    ) throws {
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw DeviceBackupError.invalidBackupFile
        }
        let directoryMode = try fileManager.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        guard directoryMode?.uint16Value == 0o700 else {
            throw DeviceBackupError.invalidBackupFile
        }
        let names = try fileManager.contentsOfDirectory(atPath: directory.path).sorted()
        guard names == ["flash-8MiB.bin", "receipt-v1.json"] else {
            throw DeviceBackupError.invalidBackupFile
        }
        let flashURL = directory.appendingPathComponent("flash-8MiB.bin")
        try validateReadFile(flashURL)
        guard try RuntimePayloadDigest.sha256(of: flashURL) == expectedDigest else {
            throw DeviceBackupError.invalidBackupFile
        }
        let receiptURL = directory.appendingPathComponent("receipt-v1.json")
        let receiptValues = try receiptURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        let receiptMode = try fileManager.attributesOfItem(atPath: receiptURL.path)[.posixPermissions] as? NSNumber
        guard receiptValues.isRegularFile == true,
              receiptValues.isSymbolicLink != true,
              receiptMode?.uint16Value == 0o600 else {
            throw DeviceBackupError.invalidBackupFile
        }
        guard let receiptData = try? Data(contentsOf: receiptURL),
              let decodedReceipt = try? JSONDecoder().decode(
                  DeviceBackupReceiptDocument.self,
                  from: receiptData
              ),
              decodedReceipt == expectedReceipt else {
            throw DeviceBackupError.invalidBackupFile
        }
    }

    private func renameItem(at sourceURL: URL, to destinationURL: URL) throws {
        let result = sourceURL.path.withCString { sourcePath in
            destinationURL.path.withCString { destinationPath in
                Darwin.rename(sourcePath, destinationPath)
            }
        }
        guard result == 0 else { throw DeviceBackupError.fileFailure }
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }

    private static func fileTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: Date())
    }
}

enum DeviceBackupError: LocalizedError {
    case invalidDescriptor
    case noDevice
    case multipleDevices
    case unsupportedUSBDevice
    case downloadModeRequired
    case cannotOpenSerialPort
    case wrongChip
    case wrongFlashSize
    case secureBootEnabled
    case flashEncryptionEnabled
    case secureDownloadMode
    case identityChanged
    case commandNotAllowed
    case toolLaunchFailed
    case toolTimedOut
    case toolFailed(exitCode: Int32)
    case invalidToolOutput
    case invalidBackupFile
    case doubleReadMismatch
    case fileFailure

    var errorDescription: String? {
        switch self {
        case .invalidDescriptor:
            "M4-4C 设备备份清单无效。"
        case .noDevice:
            "没有发现 StickS3。请连接 USB-C 数据线后重试。"
        case .multipleDevices:
            "发现多个匹配设备。请只保留一台 StickS3 后重试。"
        case .unsupportedUSBDevice:
            "USB 设备不是受支持的 StickS3 Serial/JTAG 接口。"
        case .downloadModeRequired:
            "设备尚未进入下载模式。请长按侧面电源键，直到蓝灯双闪且屏幕熄灭，再重新开始。"
        case .cannotOpenSerialPort:
            "无法独占打开设备串口。请关闭其他串口工具、重新连接设备后重试。"
        case .wrongChip:
            "设备芯片不是固定要求的 ESP32-S3；操作已停止。"
        case .wrongFlashSize:
            "设备 Flash 不是固定要求的 8 MiB；操作已停止。"
        case .secureBootEnabled:
            "设备已启用 Secure Boot；当前无密钥恢复流程不能安全继续。"
        case .flashEncryptionEnabled:
            "设备已启用 Flash Encryption；当前备份无法作为明文恢复源。"
        case .secureDownloadMode:
            "设备处于 Secure Download Mode；当前只读完整备份流程不能安全继续。"
        case .identityChanged:
            "备份前复检发现设备身份变化；没有保留任何备份半成品。"
        case .commandNotAllowed:
            "请求的设备命令不在 M4-4C 只读白名单中。"
        case .toolLaunchFailed:
            "无法启动已验证的本地 esptool。"
        case .toolTimedOut:
            "只读设备操作超时；临时备份已清理。"
        case .toolFailed(let exitCode):
            "只读设备操作失败（退出码 \(exitCode)）；未执行擦除或写入。"
        case .invalidToolOutput:
            "设备返回的信息不完整或格式不符合固定 esptool 5.3.1 契约。"
        case .invalidBackupFile:
            "备份文件的类型、权限、大小或摘要未通过检查。"
        case .doubleReadMismatch:
            "两次完整读取的 SHA-256 不一致；不可靠的备份已删除。"
        case .fileFailure:
            "无法安全建立私有备份目录或回执。"
        }
    }
}
