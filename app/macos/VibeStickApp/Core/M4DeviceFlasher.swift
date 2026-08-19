import Darwin
import Foundation

enum DeviceFlashPhase: Equatable, Sendable {
    case checking
    case ready
    case writing
    case writeUnverified
    case verifying
    case verified
    case recoveryRequired
    case restoring
    case restoreUnverified
    case verifyingRestore
    case restored
    case blocked
    case failed
}

struct DeviceFlashSnapshot: Equatable, Sendable {
    let phase: DeviceFlashPhase
    let detail: String
    let payloadVersion: String?
    let backupReady: Bool

    static let checking = DeviceFlashSnapshot(
        phase: .checking,
        detail: "正在本地复核固件载荷、私有备份与中断状态；不会访问设备。",
        payloadVersion: nil,
        backupReady: false
    )

    static func ready(payloadVersion: String) -> Self {
        Self(
            phase: .ready,
            detail: "固件载荷与至少一份私有完整备份均已通过本地检查。写入仍需新的明确确认。",
            payloadVersion: payloadVersion,
            backupReady: true
        )
    }

    static func writing(payloadVersion: String) -> Self {
        Self(
            phase: .writing,
            detail: "正在写入三个固定固件范围；设备将保持在 ROM 下载模式，等待独立验证。",
            payloadVersion: payloadVersion,
            backupReady: true
        )
    }

    static func writeUnverified(payloadVersion: String) -> Self {
        Self(
            phase: .writeUnverified,
            detail: "工具已完成写入及其内建校验；尚未执行独立读回与 NVS 保留验证。",
            payloadVersion: payloadVersion,
            backupReady: true
        )
    }

    static func verifying(payloadVersion: String) -> Self {
        Self(
            phase: .verifying,
            detail: "正在独立读回三个固件范围与 NVS，并与载荷和紧邻写入前的 NVS 快照比较。",
            payloadVersion: payloadVersion,
            backupReady: true
        )
    }

    static func verified(payloadVersion: String) -> Self {
        Self(
            phase: .verified,
            detail: "三个固件范围逐项一致，NVS 未改变；设备已复位，等待功能与真机验收。",
            payloadVersion: payloadVersion,
            backupReady: true
        )
    }

    static func recoveryRequired(payloadVersion: String?, detail: String) -> Self {
        Self(
            phase: .recoveryRequired,
            detail: detail,
            payloadVersion: payloadVersion,
            backupReady: true
        )
    }

    static func restoring(payloadVersion: String?) -> Self {
        Self(
            phase: .restoring,
            detail: "正在将已验证的原始 8 MiB 镜像写回同一设备；完成后仍需独立恢复验证。",
            payloadVersion: payloadVersion,
            backupReady: true
        )
    }

    static func restoreUnverified(payloadVersion: String?) -> Self {
        Self(
            phase: .restoreUnverified,
            detail: "完整备份已写回，但尚未执行独立的 8 MiB 读回验证。",
            payloadVersion: payloadVersion,
            backupReady: true
        )
    }

    static func verifyingRestore(payloadVersion: String?) -> Self {
        Self(
            phase: .verifyingRestore,
            detail: "正在完整读回 8 MiB Flash，并与恢复源摘要比较。",
            payloadVersion: payloadVersion,
            backupReady: true
        )
    }

    static func restored(payloadVersion: String?) -> Self {
        Self(
            phase: .restored,
            detail: "完整读回与原始备份一致；设备已复位，等待恢复后的功能验收。",
            payloadVersion: payloadVersion,
            backupReady: true
        )
    }

    static func failure(_ error: Error, payloadVersion: String? = nil) -> Self {
        let flashError = error as? DeviceFlashError
        let phase: DeviceFlashPhase
        switch flashError {
        case .noBackup, .invalidBackup, .invalidPrewriteNVSSnapshot, .invalidPayload, .runtimeBusy, .identityChanged,
             .wrongDevice, .unsafeTransactionState:
            phase = .blocked
        default:
            phase = .failed
        }
        return Self(
            phase: phase,
            detail: error.localizedDescription,
            payloadVersion: payloadVersion,
            backupReady: ![.noBackup, .invalidBackup].contains(flashError),
        )
    }
}

struct DeviceFlashPlan: Equatable, Sendable {
    struct Region: Equatable, Sendable {
        let path: String
        let offset: UInt64
        let size: UInt64
        let eraseStart: UInt64
        let eraseEndExclusive: UInt64
        let sha256: String
    }

    static let sectorSize: UInt64 = 0x1000
    let regions: [Region]
    let preservedNVS: FirmwarePreservedRange

    init(manifest: FirmwarePayloadManifest) throws {
        guard manifest.target == "esp32s3",
              manifest.flash == FirmwareFlashGeometry(
                  frequency: "80m",
                  mode: "dio",
                  size: FirmwarePayloadValidator.flashSize
              ),
              manifest.preservedRanges == [FirmwarePayloadValidator.preservedNVS] else {
            throw DeviceFlashError.invalidPayload
        }

        let sorted = manifest.files.sorted { $0.offset < $1.offset }
        guard sorted.count == FirmwarePayloadValidator.requiredOffsets.count else {
            throw DeviceFlashError.invalidPayload
        }
        var names = Set<String>()
        var built: [Region] = []
        for entry in sorted {
            guard FirmwarePayloadValidator.requiredOffsets[entry.path] == entry.offset,
                  names.insert(entry.path).inserted,
                  entry.size > 0,
                  entry.offset <= FirmwarePayloadValidator.flashSize,
                  entry.size <= FirmwarePayloadValidator.flashSize - entry.offset else {
                throw DeviceFlashError.invalidPayload
            }
            let end = entry.offset + entry.size
            let eraseStart = entry.offset / Self.sectorSize * Self.sectorSize
            let eraseEnd = ((end + Self.sectorSize - 1) / Self.sectorSize) * Self.sectorSize
            guard eraseEnd <= FirmwarePayloadValidator.flashSize,
                  !(eraseStart < FirmwarePayloadValidator.preservedNVS.endExclusive
                    && eraseEnd > FirmwarePayloadValidator.preservedNVS.start) else {
                throw DeviceFlashError.nvsOverlap
            }
            built.append(
                Region(
                    path: entry.path,
                    offset: entry.offset,
                    size: entry.size,
                    eraseStart: eraseStart,
                    eraseEndExclusive: eraseEnd,
                    sha256: entry.sha256
                )
            )
        }
        guard names == Set(FirmwarePayloadValidator.requiredOffsets.keys) else {
            throw DeviceFlashError.invalidPayload
        }
        for index in 1..<built.count where built[index - 1].eraseEndExclusive > built[index].eraseStart {
            throw DeviceFlashError.overlappingEraseRanges
        }
        regions = built
        preservedNVS = FirmwarePayloadValidator.preservedNVS
    }
}

enum DeviceFlashCommandPolicy {
    static let forbiddenArguments = [
        "erase-flash", "erase-region", "--erase-all", "--force", "--encrypt",
        "--encrypt-files", "--ignore-flash-enc-efuse", "--diff-with",
        "--trust-flash-content", "--skip-flashed", "verify-flash", "write-mem",
        "write-flash-status", "load-ram",
    ]
    static let allowedCommands = [
        "get-security-info", "flash-id", "read-mac", "read-flash", "write-flash",
    ]

    static func validate(_ arguments: [String], expectedCommand: String) throws {
        guard expectedCommand == "get-security-info"
                || expectedCommand == "flash-id"
                || expectedCommand == "read-mac"
                || expectedCommand == "read-flash"
                || expectedCommand == "write-flash",
              arguments.contains("--chip"),
              arguments.contains("esp32s3"),
              arguments.contains("--no-stub"),
              arguments.contains("--before"),
              arguments.contains("no-reset"),
              arguments.filter({ allowedCommands.contains($0) }) == [expectedCommand],
              forbiddenArguments.allSatisfy({ !arguments.contains($0) }) else {
            throw DeviceFlashError.commandNotAllowed
        }
    }
}

private struct DeviceRecoveryReceiptDocument: Codable, Equatable, Sendable {
    struct FlashImage: Codable, Equatable, Sendable {
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

private struct ValidatedDeviceBackup: Sendable {
    let directory: URL
    let imageURL: URL
    let receiptURL: URL
    let receipt: DeviceRecoveryReceiptDocument
}

private enum DeviceFlashOperation: String, Codable, Sendable {
    case candidateWrite = "candidate-write"
    case candidateVerification = "candidate-verification"
    case fullRestore = "full-restore"
    case restoreVerification = "restore-verification"
}

private enum DeviceFlashPersistentPhase: String, Codable, Sendable {
    case writing
    case writeUnverified = "write-unverified"
    case verifying
    case verified
    case recoveryRequired = "recovery-required"
    case restoring
    case restoreUnverified = "restore-unverified"
    case verifyingRestore = "verifying-restore"
    case restored
    case failed
}

private struct DeviceFlashJournal: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let operation: DeviceFlashOperation
    let phase: DeviceFlashPersistentPhase
    let createdAt: String
    let updatedAt: String
    let payloadVersion: String
    let payloadManifestSHA256: String
    let backupSHA256: String
    let deviceFingerprint: String
    let prewriteNVSSHA256: String?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case operation
        case phase
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case payloadVersion = "payload_version"
        case payloadManifestSHA256 = "payload_manifest_sha256"
        case backupSHA256 = "backup_sha256"
        case deviceFingerprint = "device_fingerprint_sha256"
        case prewriteNVSSHA256 = "prewrite_nvs_sha256"
    }

    func updating(operation: DeviceFlashOperation? = nil, phase: DeviceFlashPersistentPhase) -> Self {
        Self(
            schemaVersion: schemaVersion,
            operation: operation ?? self.operation,
            phase: phase,
            createdAt: createdAt,
            updatedAt: DeviceFlashManager.timestamp(),
            payloadVersion: payloadVersion,
            payloadManifestSHA256: payloadManifestSHA256,
            backupSHA256: backupSHA256,
            deviceFingerprint: deviceFingerprint,
            prewriteNVSSHA256: prewriteNVSSHA256
        )
    }
}

private struct DeviceFlashLocalContext: Sendable {
    let manifest: FirmwarePayloadManifest
    let manifestDigest: String
    let plan: DeviceFlashPlan
    let backups: [ValidatedDeviceBackup]
}

actor DeviceFlashManager {
    private let descriptor: DeviceBackupDescriptor
    private let firmwareRoot: URL
    private let backupRoot: URL
    private let transactionRoot: URL
    private let recordingFile: URL
    private let deviceDetector: any USBDeviceDetecting
    private let runner: any DeviceToolRunning
    private let fileManager: FileManager

    init(
        descriptor: DeviceBackupDescriptor = .current,
        firmwareRoot: URL? = nil,
        backupRoot: URL = SupportPaths.supportDirectory
            .appendingPathComponent("FirmwareBackups.noindex", isDirectory: true),
        transactionRoot: URL = SupportPaths.supportDirectory
            .appendingPathComponent("FirmwareTransactions.noindex", isDirectory: true),
        recordingFile: URL = SupportPaths.recordingFile,
        deviceDetector: any USBDeviceDetecting = USBDeviceDetector(),
        runner: any DeviceToolRunning = SystemDeviceToolRunner(),
        fileManager: FileManager = .default
    ) {
        self.descriptor = descriptor
        self.firmwareRoot = firmwareRoot
            ?? Bundle.main.resourceURL?.appendingPathComponent("FirmwarePayload.noindex", isDirectory: true)
            ?? URL(fileURLWithPath: "/__vibestick_missing_firmware_payload__")
        self.backupRoot = backupRoot
        self.transactionRoot = transactionRoot
        self.recordingFile = recordingFile
        self.deviceDetector = deviceDetector
        self.runner = runner
        self.fileManager = fileManager
    }

    func inspectLocalReadiness() -> DeviceFlashSnapshot {
        do {
            let context = try validatedLocalContext()
            let journal = try loadJournal()
            if try hasInterruptedTemporaryState(journal: journal) {
                return .recoveryRequired(
                    payloadVersion: context.manifest.payloadVersion,
                    detail: "发现未完成的私有固件事务目录；不会自动续写。请先复核并选择验证或恢复。"
                )
            }
            guard let journal else {
                return .ready(payloadVersion: context.manifest.payloadVersion)
            }
            guard journal.payloadManifestSHA256 == context.manifestDigest else {
                return .recoveryRequired(
                    payloadVersion: context.manifest.payloadVersion,
                    detail: "当前固件载荷与上一次设备事务不一致；禁止自动继续，仍可从已验证备份恢复。"
                )
            }
            if journal.operation == .candidateWrite || journal.operation == .candidateVerification {
                guard (try? validatedPrewriteNVSSnapshotDigest(journal: journal, plan: context.plan)) != nil else {
                    return .recoveryRequired(
                        payloadVersion: journal.payloadVersion,
                        detail: "写入前 NVS 私有快照缺失或无效；不会继续验证，仍可从已验证备份恢复。"
                    )
                }
            }
            switch journal.phase {
            case .writeUnverified:
                return .writeUnverified(payloadVersion: journal.payloadVersion)
            case .verified:
                return .verified(payloadVersion: journal.payloadVersion)
            case .restoreUnverified:
                return .restoreUnverified(payloadVersion: journal.payloadVersion)
            case .restored:
                return .restored(payloadVersion: journal.payloadVersion)
            case .writing, .verifying, .recoveryRequired, .restoring, .verifyingRestore, .failed:
                return .recoveryRequired(
                    payloadVersion: journal.payloadVersion,
                    detail: "上一次设备事务没有形成完整验收结果；不会自动重试、验证或恢复。"
                )
            }
        } catch {
            return .failure(error)
        }
    }

    func writeCandidate(executableURL: URL) async throws -> DeviceFlashSnapshot {
        try requireRuntimeIdle()
        let context = try validatedLocalContext()
        let workingDirectory = try makePrivateWorkingDirectory()
        defer { try? fileManager.removeItem(at: workingDirectory) }
        let (candidate, inspection) = try await inspectConnectedDevice(
            executableURL: executableURL,
            workingDirectory: workingDirectory
        )
        let backup = try matchingBackup(for: inspection, in: context.backups)
        let nvsSize = context.plan.preservedNVS.endExclusive - context.plan.preservedNVS.start
        let prewriteNVSURL = workingDirectory.appendingPathComponent("prewrite-nvs.bin")
        try preparePrivateOutputFile(prewriteNVSURL)
        let prewriteNVSArguments = try readArguments(
            candidate: candidate,
            offset: context.plan.preservedNVS.start,
            size: nvsSize,
            outputURL: prewriteNVSURL,
            resetAfterCommand: false
        )
        _ = try run(
            executableURL: executableURL,
            arguments: prewriteNVSArguments,
            expectedCommand: "read-flash",
            workingDirectory: workingDirectory,
            timeout: 120
        )
        let prewriteNVSDigest = try persistPrewriteNVSSnapshot(
            from: prewriteNVSURL,
            expectedSize: nvsSize
        )
        var journal = DeviceFlashJournal(
            schemaVersion: 1,
            operation: .candidateWrite,
            phase: .writing,
            createdAt: Self.timestamp(),
            updatedAt: Self.timestamp(),
            payloadVersion: context.manifest.payloadVersion,
            payloadManifestSHA256: context.manifestDigest,
            backupSHA256: backup.receipt.image.sha256,
            deviceFingerprint: inspection.deviceFingerprint,
            prewriteNVSSHA256: prewriteNVSDigest
        )
        try writeJournal(journal)

        let arguments = try candidateWriteArguments(
            candidate: candidate,
            plan: context.plan,
            resetAfterCommand: false
        )
        do {
            let result = try run(
                executableURL: executableURL,
                arguments: arguments,
                expectedCommand: "write-flash",
                workingDirectory: workingDirectory,
                timeout: 900
            )
            try DeviceWriteOutputParser.validate(result)
        } catch {
            journal = journal.updating(phase: .recoveryRequired)
            try? writeJournal(journal)
            throw DeviceFlashError.writeFailed
        }
        journal = journal.updating(phase: .writeUnverified)
        try writeJournal(journal)
        return .writeUnverified(payloadVersion: context.manifest.payloadVersion)
    }

    func verifyCandidate(executableURL: URL) async throws -> DeviceFlashSnapshot {
        try requireRuntimeIdle()
        let context = try validatedLocalContext()
        guard var journal = try loadJournal(),
              journal.operation == .candidateWrite,
              journal.phase == .writeUnverified || journal.phase == .recoveryRequired,
              journal.payloadManifestSHA256 == context.manifestDigest else {
            throw DeviceFlashError.unsafeTransactionState
        }
        let expectedNVSDigest = try validatedPrewriteNVSSnapshotDigest(
            journal: journal,
            plan: context.plan
        )
        let workingDirectory = try makePrivateWorkingDirectory()
        defer { try? fileManager.removeItem(at: workingDirectory) }
        let (candidate, inspection) = try await inspectConnectedDevice(
            executableURL: executableURL,
            workingDirectory: workingDirectory
        )
        let backup = try matchingBackup(for: inspection, in: context.backups)
        guard inspection.deviceFingerprint == journal.deviceFingerprint,
              backup.receipt.image.sha256 == journal.backupSHA256 else {
            throw DeviceFlashError.identityChanged
        }

        journal = journal.updating(operation: .candidateVerification, phase: .verifying)
        try writeJournal(journal)
        do {
            for region in context.plan.regions {
                let outputURL = workingDirectory.appendingPathComponent("verify-\(region.path)")
                try preparePrivateOutputFile(outputURL)
                let arguments = try readArguments(
                    candidate: candidate,
                    offset: region.offset,
                    size: region.size,
                    outputURL: outputURL,
                    resetAfterCommand: false
                )
                _ = try run(
                    executableURL: executableURL,
                    arguments: arguments,
                    expectedCommand: "read-flash",
                    workingDirectory: workingDirectory,
                    timeout: 300
                )
                try validatePrivateRead(outputURL, expectedSize: region.size)
                guard try RuntimePayloadDigest.sha256(of: outputURL) == region.sha256 else {
                    throw DeviceFlashError.candidateMismatch
                }
            }

            let nvsSize = context.plan.preservedNVS.endExclusive - context.plan.preservedNVS.start
            let nvsURL = workingDirectory.appendingPathComponent("verify-nvs.bin")
            try preparePrivateOutputFile(nvsURL)
            let nvsArguments = try readArguments(
                candidate: candidate,
                offset: context.plan.preservedNVS.start,
                size: nvsSize,
                outputURL: nvsURL,
                resetAfterCommand: true
            )
            _ = try run(
                executableURL: executableURL,
                arguments: nvsArguments,
                expectedCommand: "read-flash",
                workingDirectory: workingDirectory,
                timeout: 120
            )
            try validatePrivateRead(nvsURL, expectedSize: nvsSize)
            guard try RuntimePayloadDigest.sha256(of: nvsURL) == expectedNVSDigest else {
                throw DeviceFlashError.nvsMismatch
            }
        } catch {
            journal = journal.updating(phase: .recoveryRequired)
            try? writeJournal(journal)
            throw error
        }
        journal = journal.updating(phase: .verified)
        try writeJournal(journal)
        return .verified(payloadVersion: context.manifest.payloadVersion)
    }

    func restoreBackup(executableURL: URL) async throws -> DeviceFlashSnapshot {
        try requireRuntimeIdle()
        let context = try validatedLocalContext()
        let workingDirectory = try makePrivateWorkingDirectory()
        defer { try? fileManager.removeItem(at: workingDirectory) }
        let (candidate, inspection) = try await inspectConnectedDevice(
            executableURL: executableURL,
            workingDirectory: workingDirectory
        )
        let backup = try matchingBackup(for: inspection, in: context.backups)
        var journal = DeviceFlashJournal(
            schemaVersion: 1,
            operation: .fullRestore,
            phase: .restoring,
            createdAt: Self.timestamp(),
            updatedAt: Self.timestamp(),
            payloadVersion: context.manifest.payloadVersion,
            payloadManifestSHA256: context.manifestDigest,
            backupSHA256: backup.receipt.image.sha256,
            deviceFingerprint: inspection.deviceFingerprint,
            prewriteNVSSHA256: nil
        )
        try writeJournal(journal)
        try removePrewriteNVSSnapshotIfPresent()
        let arguments = try restoreArguments(
            candidate: candidate,
            backupURL: backup.imageURL,
            resetAfterCommand: false
        )
        do {
            let result = try run(
                executableURL: executableURL,
                arguments: arguments,
                expectedCommand: "write-flash",
                workingDirectory: workingDirectory,
                timeout: 1800
            )
            try DeviceWriteOutputParser.validate(result)
        } catch {
            journal = journal.updating(phase: .recoveryRequired)
            try? writeJournal(journal)
            throw DeviceFlashError.restoreFailed
        }
        journal = journal.updating(phase: .restoreUnverified)
        try writeJournal(journal)
        return .restoreUnverified(payloadVersion: context.manifest.payloadVersion)
    }

    func verifyRestore(executableURL: URL) async throws -> DeviceFlashSnapshot {
        try requireRuntimeIdle()
        let context = try validatedLocalContext()
        guard var journal = try loadJournal(),
              journal.operation == .fullRestore,
              journal.phase == .restoreUnverified || journal.phase == .recoveryRequired else {
            throw DeviceFlashError.unsafeTransactionState
        }
        let workingDirectory = try makePrivateWorkingDirectory()
        defer { try? fileManager.removeItem(at: workingDirectory) }
        let (candidate, inspection) = try await inspectConnectedDevice(
            executableURL: executableURL,
            workingDirectory: workingDirectory
        )
        let backup = try matchingBackup(for: inspection, in: context.backups)
        guard inspection.deviceFingerprint == journal.deviceFingerprint,
              backup.receipt.image.sha256 == journal.backupSHA256 else {
            throw DeviceFlashError.identityChanged
        }

        journal = journal.updating(operation: .restoreVerification, phase: .verifyingRestore)
        try writeJournal(journal)
        do {
            let outputURL = workingDirectory.appendingPathComponent("verify-restored-8MiB.bin")
            try preparePrivateOutputFile(outputURL)
            let arguments = try readArguments(
                candidate: candidate,
                offset: 0,
                size: descriptor.flashSizeBytes,
                outputURL: outputURL,
                resetAfterCommand: true
            )
            _ = try run(
                executableURL: executableURL,
                arguments: arguments,
                expectedCommand: "read-flash",
                workingDirectory: workingDirectory,
                timeout: 900
            )
            try validatePrivateRead(outputURL, expectedSize: descriptor.flashSizeBytes)
            guard try RuntimePayloadDigest.sha256(of: outputURL) == backup.receipt.image.sha256 else {
                throw DeviceFlashError.restoreMismatch
            }
        } catch {
            journal = journal.updating(phase: .recoveryRequired)
            try? writeJournal(journal)
            throw error
        }
        journal = journal.updating(phase: .restored)
        try writeJournal(journal)
        return .restored(payloadVersion: context.manifest.payloadVersion)
    }

    private func validatedLocalContext() throws -> DeviceFlashLocalContext {
        try descriptor.validate()
        let manifest: FirmwarePayloadManifest
        do {
            manifest = try FirmwarePayloadValidator.validate(root: firmwareRoot)
        } catch {
            throw DeviceFlashError.invalidPayload
        }
        let plan = try DeviceFlashPlan(manifest: manifest)
        let manifestURL = firmwareRoot.appendingPathComponent(FirmwarePayloadValidator.manifestName)
        let manifestDigest = try RuntimePayloadDigest.sha256(of: manifestURL)
        let backups = try validatedBackups()
        guard !backups.isEmpty else { throw DeviceFlashError.noBackup }
        return DeviceFlashLocalContext(
            manifest: manifest,
            manifestDigest: manifestDigest,
            plan: plan,
            backups: backups
        )
    }

    private func validatedBackups() throws -> [ValidatedDeviceBackup] {
        guard fileManager.fileExists(atPath: backupRoot.path) else {
            throw DeviceFlashError.noBackup
        }
        let rootValues = try backupRoot.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        let rootMode = try permissions(of: backupRoot)
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true, rootMode == 0o700 else {
            throw DeviceFlashError.invalidBackup
        }
        let entries = try fileManager.contentsOfDirectory(
            at: backupRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        )
        var backups: [ValidatedDeviceBackup] = []
        for directory in entries {
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true,
                  try permissions(of: directory) == 0o700 else {
                throw DeviceFlashError.invalidBackup
            }
            let names = try fileManager.contentsOfDirectory(atPath: directory.path).sorted()
            guard names == ["flash-8MiB.bin", "receipt-v1.json"] else {
                throw DeviceFlashError.invalidBackup
            }
            let imageURL = directory.appendingPathComponent("flash-8MiB.bin")
            let receiptURL = directory.appendingPathComponent("receipt-v1.json")
            try validatePrivateRead(imageURL, expectedSize: descriptor.flashSizeBytes)
            let receiptValues = try receiptURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard receiptValues.isRegularFile == true, receiptValues.isSymbolicLink != true,
                  try permissions(of: receiptURL) == 0o600,
                  let data = try? Data(contentsOf: receiptURL),
                  let receipt = try? JSONDecoder().decode(DeviceRecoveryReceiptDocument.self, from: data),
                  receipt.schemaVersion == 1,
                  receipt.tool == "esptool",
                  receipt.toolVersion == descriptor.toolVersion,
                  receipt.chip == descriptor.expectedChip,
                  receipt.flashSizeBytes == descriptor.flashSizeBytes,
                  !receipt.secureBootEnabled,
                  !receipt.flashEncryptionEnabled,
                  receipt.deviceFingerprint.isLowercaseSHA256,
                  receipt.image.path == "flash-8MiB.bin",
                  receipt.image.offset == "0x0",
                  receipt.image.size == descriptor.flashSizeBytes,
                  receipt.image.sha256.isLowercaseSHA256,
                  receipt.image.verification == "two-complete-reads-sha256-match",
                  try RuntimePayloadDigest.sha256(of: imageURL) == receipt.image.sha256 else {
                throw DeviceFlashError.invalidBackup
            }
            backups.append(
                ValidatedDeviceBackup(
                    directory: directory,
                    imageURL: imageURL,
                    receiptURL: receiptURL,
                    receipt: receipt
                )
            )
        }
        return backups.sorted { $0.receipt.createdAt > $1.receipt.createdAt }
    }

    private func matchingBackup(
        for inspection: DeviceSecurityInspection,
        in backups: [ValidatedDeviceBackup]
    ) throws -> ValidatedDeviceBackup {
        guard let backup = backups.first(where: {
            $0.receipt.deviceFingerprint == inspection.deviceFingerprint
                && $0.receipt.flashManufacturerID == inspection.flashManufacturerID
                && $0.receipt.flashDeviceID == inspection.flashDeviceID
        }) else {
            throw DeviceFlashError.identityChanged
        }
        return backup
    }

    private func inspectConnectedDevice(
        executableURL: URL,
        workingDirectory: URL
    ) async throws -> (USBDeviceCandidate, DeviceSecurityInspection) {
        let candidates = await deviceDetector.detectAll()
        guard candidates.count == 1 else {
            throw candidates.isEmpty ? DeviceFlashError.wrongDevice : DeviceFlashError.multipleDevices
        }
        let candidate = candidates[0]
        guard candidate.vendorID == USBDeviceCandidate.esp32S3VendorID,
              candidate.productID == USBDeviceCandidate.usbSerialJTAGProductID,
              candidate.portPath.hasPrefix("/dev/cu.usbmodem"),
              !candidate.portPath.contains("..") else {
            throw DeviceFlashError.wrongDevice
        }
        let security = try run(
            executableURL: executableURL,
            arguments: try readOnlyArguments(candidate: candidate, command: ["get-security-info"]),
            expectedCommand: "get-security-info",
            workingDirectory: workingDirectory,
            timeout: 45
        )
        let flash = try run(
            executableURL: executableURL,
            arguments: try readOnlyArguments(
                candidate: candidate,
                command: ["flash-id", "--spi-connection", "SPI"]
            ),
            expectedCommand: "flash-id",
            workingDirectory: workingDirectory,
            timeout: 45
        )
        let mac = try run(
            executableURL: executableURL,
            arguments: try readOnlyArguments(candidate: candidate, command: ["read-mac"]),
            expectedCommand: "read-mac",
            workingDirectory: workingDirectory,
            timeout: 45
        )
        let inspection = try DeviceInspectionOutputParser.parse(
            securityOutput: security.standardOutput + "\n" + security.standardError,
            flashOutput: flash.standardOutput + "\n" + flash.standardError,
            macOutput: mac.standardOutput + "\n" + mac.standardError,
            descriptor: descriptor,
            inspectedAt: Self.timestamp()
        )
        return (candidate, inspection)
    }

    private func readOnlyArguments(candidate: USBDeviceCandidate, command: [String]) throws -> [String] {
        guard let expectedCommand = command.first,
              ["get-security-info", "flash-id", "read-mac"].contains(expectedCommand) else {
            throw DeviceFlashError.commandNotAllowed
        }
        let arguments = baseArguments(candidate: candidate, resetAfterCommand: false) + command
        try DeviceFlashCommandPolicy.validate(arguments, expectedCommand: expectedCommand)
        return arguments
    }

    private func candidateWriteArguments(
        candidate: USBDeviceCandidate,
        plan: DeviceFlashPlan,
        resetAfterCommand: Bool
    ) throws -> [String] {
        var command = [
            "write-flash", "--flash-size", "keep", "--flash-mode", "keep",
            "--flash-freq", "keep", "--spi-connection", "SPI", "--no-progress",
        ]
        for region in plan.regions {
            command.append(String(format: "0x%llx", region.offset))
            command.append(firmwareRoot.appendingPathComponent(region.path).path)
        }
        let arguments = baseArguments(candidate: candidate, resetAfterCommand: resetAfterCommand) + command
        try DeviceFlashCommandPolicy.validate(arguments, expectedCommand: "write-flash")
        return arguments
    }

    private func restoreArguments(
        candidate: USBDeviceCandidate,
        backupURL: URL,
        resetAfterCommand: Bool
    ) throws -> [String] {
        let command = [
            "write-flash", "--flash-size", "keep", "--flash-mode", "keep",
            "--flash-freq", "keep", "--spi-connection", "SPI", "--no-progress",
            "0x0", backupURL.path,
        ]
        let arguments = baseArguments(candidate: candidate, resetAfterCommand: resetAfterCommand) + command
        try DeviceFlashCommandPolicy.validate(arguments, expectedCommand: "write-flash")
        return arguments
    }

    private func readArguments(
        candidate: USBDeviceCandidate,
        offset: UInt64,
        size: UInt64,
        outputURL: URL,
        resetAfterCommand: Bool
    ) throws -> [String] {
        let outputParent = outputURL.deletingLastPathComponent().standardizedFileURL
        guard outputURL.standardizedFileURL.deletingLastPathComponent() == outputParent,
              outputParent.path.hasPrefix(transactionRoot.standardizedFileURL.path + "/") else {
            throw DeviceFlashError.commandNotAllowed
        }
        let command = [
            "read-flash", "--flash-size", descriptor.expectedFlashSizeLabel, "--no-progress",
            String(format: "0x%llx", offset), String(format: "0x%llx", size), outputURL.path,
        ]
        let arguments = baseArguments(candidate: candidate, resetAfterCommand: resetAfterCommand) + command
        try DeviceFlashCommandPolicy.validate(arguments, expectedCommand: "read-flash")
        return arguments
    }

    private func baseArguments(
        candidate: USBDeviceCandidate,
        resetAfterCommand: Bool
    ) -> [String] {
        [
            "--chip", "esp32s3",
            "--port", candidate.portPath,
            "--baud", String(descriptor.baudRate),
            "--before", "no-reset",
            "--after", resetAfterCommand ? "watchdog-reset" : "no-reset",
            "--no-stub",
            "--connect-attempts", "3",
        ]
    }

    private func run(
        executableURL: URL,
        arguments: [String],
        expectedCommand: String,
        workingDirectory: URL,
        timeout: TimeInterval
    ) throws -> DeviceToolResult {
        guard executableURL.lastPathComponent == "esptool" else {
            throw DeviceFlashError.commandNotAllowed
        }
        try DeviceFlashCommandPolicy.validate(arguments, expectedCommand: expectedCommand)
        do {
            return try runner.run(
                executableURL: executableURL,
                arguments: arguments,
                workingDirectory: workingDirectory,
                timeout: timeout
            )
        } catch {
            throw DeviceFlashError.toolFailure
        }
    }

    private func requireRuntimeIdle() throws {
        guard fileManager.fileExists(atPath: recordingFile.path) else { return }
        let values = try recordingFile.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let data = try? Data(contentsOf: recordingFile),
              let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = document["status"] as? String else {
            throw DeviceFlashError.runtimeBusy
        }
        let active = document["active"] as? Bool ?? false
        guard !active, !["recording", "transcribing", "pending_send"].contains(status) else {
            throw DeviceFlashError.runtimeBusy
        }
    }

    private func makePrivateWorkingDirectory() throws -> URL {
        try prepareTransactionRoot()
        let directory = transactionRoot.appendingPathComponent(
            ".DeviceFlash.partial-\(UUID().uuidString.lowercased())",
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
            throw DeviceFlashError.fileFailure
        }
    }

    private func prepareTransactionRoot() throws {
        do {
            try fileManager.createDirectory(
                at: transactionRoot,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let values = try transactionRoot.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw DeviceFlashError.fileFailure
            }
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: transactionRoot.path)
        } catch let error as DeviceFlashError {
            throw error
        } catch {
            throw DeviceFlashError.fileFailure
        }
    }

    private func preparePrivateOutputFile(_ url: URL) throws {
        guard fileManager.createFile(
            atPath: url.path,
            contents: Data(),
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw DeviceFlashError.fileFailure
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func validatePrivateRead(_ url: URL, expectedSize: UInt64) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        let size = (try fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              try permissions(of: url) == 0o600,
              size == expectedSize else {
            throw DeviceFlashError.fileFailure
        }
    }

    private func permissions(of url: URL) throws -> UInt16 {
        let value = try fileManager.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        return value?.uint16Value ?? 0
    }

    private var prewriteNVSSnapshotURL: URL {
        transactionRoot.appendingPathComponent("prewrite-nvs-v1.bin")
    }

    private func persistPrewriteNVSSnapshot(from sourceURL: URL, expectedSize: UInt64) throws -> String {
        try validatePrivateRead(sourceURL, expectedSize: expectedSize)
        let digest = try RuntimePayloadDigest.sha256(of: sourceURL)
        try prepareTransactionRoot()
        let destinationURL = prewriteNVSSnapshotURL
        if fileManager.fileExists(atPath: destinationURL.path) {
            let values = try destinationURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw DeviceFlashError.fileFailure
            }
        }
        let temporaryURL = transactionRoot.appendingPathComponent(
            ".prewrite-nvs-v1.bin.tmp-\(UUID().uuidString.lowercased())"
        )
        do {
            let data = try Data(contentsOf: sourceURL)
            guard UInt64(data.count) == expectedSize else { throw DeviceFlashError.fileFailure }
            try data.write(to: temporaryURL, options: [.atomic])
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporaryURL.path)
            let result = temporaryURL.path.withCString { source in
                destinationURL.path.withCString { destination in
                    Darwin.rename(source, destination)
                }
            }
            guard result == 0 else { throw DeviceFlashError.fileFailure }
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destinationURL.path)
            try validatePrivateRead(destinationURL, expectedSize: expectedSize)
            guard try RuntimePayloadDigest.sha256(of: destinationURL) == digest else {
                throw DeviceFlashError.fileFailure
            }
            return digest
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw DeviceFlashError.fileFailure
        }
    }

    private func validatedPrewriteNVSSnapshotDigest(
        journal: DeviceFlashJournal,
        plan: DeviceFlashPlan
    ) throws -> String {
        let expectedSize = plan.preservedNVS.endExclusive - plan.preservedNVS.start
        guard let expectedDigest = journal.prewriteNVSSHA256,
              expectedDigest.isLowercaseSHA256 else {
            throw DeviceFlashError.invalidPrewriteNVSSnapshot
        }
        do {
            try validatePrivateRead(prewriteNVSSnapshotURL, expectedSize: expectedSize)
            guard try RuntimePayloadDigest.sha256(of: prewriteNVSSnapshotURL) == expectedDigest else {
                throw DeviceFlashError.invalidPrewriteNVSSnapshot
            }
        } catch let error as DeviceFlashError {
            throw error == .invalidPrewriteNVSSnapshot ? error : .invalidPrewriteNVSSnapshot
        } catch {
            throw DeviceFlashError.invalidPrewriteNVSSnapshot
        }
        return expectedDigest
    }

    private func removePrewriteNVSSnapshotIfPresent() throws {
        guard fileManager.fileExists(atPath: prewriteNVSSnapshotURL.path) else { return }
        let values = try prewriteNVSSnapshotURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw DeviceFlashError.fileFailure
        }
        do {
            try fileManager.removeItem(at: prewriteNVSSnapshotURL)
        } catch {
            throw DeviceFlashError.fileFailure
        }
    }

    private func writeJournal(_ journal: DeviceFlashJournal) throws {
        try prepareTransactionRoot()
        let journalURL = transactionRoot.appendingPathComponent("latest-v1.json")
        if fileManager.fileExists(atPath: journalURL.path) {
            let values = try journalURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw DeviceFlashError.fileFailure
            }
        }
        let temporaryURL = transactionRoot.appendingPathComponent(
            ".latest-v1.json.tmp-\(UUID().uuidString.lowercased())"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(journal)
        data.append(0x0a)
        do {
            try data.write(to: temporaryURL, options: [.atomic])
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporaryURL.path)
            let result = temporaryURL.path.withCString { source in
                journalURL.path.withCString { destination in
                    Darwin.rename(source, destination)
                }
            }
            guard result == 0 else { throw DeviceFlashError.fileFailure }
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journalURL.path)
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw DeviceFlashError.fileFailure
        }
    }

    private func loadJournal() throws -> DeviceFlashJournal? {
        let journalURL = transactionRoot.appendingPathComponent("latest-v1.json")
        guard fileManager.fileExists(atPath: journalURL.path) else { return nil }
        let rootValues = try transactionRoot.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        let journalValues = try journalURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true,
              try permissions(of: transactionRoot) == 0o700,
              journalValues.isRegularFile == true, journalValues.isSymbolicLink != true,
              try permissions(of: journalURL) == 0o600,
              let data = try? Data(contentsOf: journalURL),
              let journal = try? JSONDecoder().decode(DeviceFlashJournal.self, from: data),
              journal.schemaVersion == 1,
              journal.payloadManifestSHA256.isLowercaseSHA256,
              journal.backupSHA256.isLowercaseSHA256,
              journal.deviceFingerprint.isLowercaseSHA256,
              journal.prewriteNVSSHA256 == nil || journal.prewriteNVSSHA256?.isLowercaseSHA256 == true else {
            throw DeviceFlashError.unsafeTransactionState
        }
        return journal
    }

    private func hasInterruptedTemporaryState(journal: DeviceFlashJournal?) throws -> Bool {
        guard fileManager.fileExists(atPath: transactionRoot.path) else { return false }
        let entries = try fileManager.contentsOfDirectory(atPath: transactionRoot.path)
        let hasTemporaryEntry = entries.contains {
            $0.hasPrefix(".DeviceFlash.partial-")
                || $0.hasPrefix(".latest-v1.json.tmp-")
                || $0.hasPrefix(".prewrite-nvs-v1.bin.tmp-")
        }
        let snapshotWithoutCandidateJournal = entries.contains(prewriteNVSSnapshotURL.lastPathComponent)
            && journal?.operation != .candidateWrite
            && journal?.operation != .candidateVerification
        return hasTemporaryEntry || snapshotWithoutCandidateJournal
    }

    static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }
}

private enum DeviceWriteOutputParser {
    static func validate(_ result: DeviceToolResult) throws {
        let combined = result.standardOutput + "\n" + result.standardError
        guard combined.contains("Hash of data verified") else {
            throw DeviceFlashError.missingWriteVerification
        }
    }
}

enum DeviceFlashError: LocalizedError, Equatable {
    case invalidPayload
    case nvsOverlap
    case overlappingEraseRanges
    case noBackup
    case invalidBackup
    case invalidPrewriteNVSSnapshot
    case wrongDevice
    case multipleDevices
    case identityChanged
    case runtimeBusy
    case unsafeTransactionState
    case commandNotAllowed
    case toolFailure
    case missingWriteVerification
    case writeFailed
    case candidateMismatch
    case nvsMismatch
    case restoreFailed
    case restoreMismatch
    case fileFailure

    var errorDescription: String? {
        switch self {
        case .invalidPayload:
            "M4-4D 固件载荷、清单或文件摘要无效。"
        case .nvsOverlap:
            "候选固件的实际擦写扇区会触及受保护的 NVS；写入已阻止。"
        case .overlappingEraseRanges:
            "候选固件的实际擦写扇区互相重叠；写入已阻止。"
        case .noBackup:
            "没有找到经过验证的 M4-4C 私有完整备份。"
        case .invalidBackup:
            "私有完整备份的类型、权限、回执、大小或摘要无效。"
        case .invalidPrewriteNVSSnapshot:
            "紧邻候选写入前保存的 NVS 私有快照缺失、权限错误或摘要无效。"
        case .wrongDevice:
            "没有发现唯一、受支持的 StickS3 USB Serial/JTAG 设备。"
        case .multipleDevices:
            "发现多个匹配设备；M4-4D 不会猜测目标。"
        case .identityChanged:
            "当前设备与已验证私有备份的身份或 Flash ID 不一致。"
        case .runtimeBusy:
            "当前语音录制、转写或待发送会话尚未结束；设备操作已阻止。"
        case .unsafeTransactionState:
            "当前私有事务状态不允许执行这一步；不会自动续写或恢复。"
        case .commandNotAllowed:
            "请求的参数不在 M4-4D 固定命令契约中。"
        case .toolFailure:
            "固定 esptool 命令未成功完成。"
        case .missingWriteVerification:
            "esptool 没有返回固定版本要求的内建写入校验结果。"
        case .writeFailed:
            "候选固件写入没有形成可信完成状态；设备可能处于部分写入状态。不会自动重试或恢复。"
        case .candidateMismatch:
            "独立读回与候选固件摘要不一致；设备需要恢复或重新写入。"
        case .nvsMismatch:
            "独立读回发现 NVS 与紧邻候选写入前的私有快照不一致；设备需要恢复。"
        case .restoreFailed:
            "完整备份恢复没有形成可信完成状态；不会自动重试或擦除。"
        case .restoreMismatch:
            "恢复后的完整 8 MiB 读回与原始备份摘要不一致。"
        case .fileFailure:
            "无法安全建立或验证 M4-4D 私有事务文件。"
        }
    }
}

private extension String {
    var isLowercaseSHA256: Bool {
        count == 64 && self == lowercased() && allSatisfy(\.isHexDigit)
    }
}
