import CryptoKit
import Darwin
import Foundation
import Security

private extension JSONEncoder {
    static var m2Configuration: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

actor DeviceConfigurationStore {
    private let fileManager: FileManager
    private let fileURL: URL

    init(
        fileManager: FileManager = .default,
        fileURL: URL = SupportPaths.deviceConfigurationFile
    ) {
        self.fileManager = fileManager
        self.fileURL = fileURL
    }

    func load() -> DeviceConfiguration {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(DeviceConfiguration.self, from: data),
              decoded.schemaVersion == DeviceConfiguration.schemaVersion else {
            return .standard
        }
        return decoded.normalized
    }

    func save(_ requested: DeviceConfiguration) throws -> DeviceConfiguration {
        let current = load()
        var normalized = requested.normalized
        normalized.revision = max(current.revision + 1, requested.revision + 1)
        try AtomicPrivateJSONFile.write(normalized, to: fileURL, fileManager: fileManager)
        return normalized
    }
}

actor DeviceRegistryStore {
    private let fileManager: FileManager
    private let fileURL: URL

    init(
        fileManager: FileManager = .default,
        fileURL: URL = SupportPaths.deviceRegistryFile
    ) {
        self.fileManager = fileManager
        self.fileURL = fileURL
    }

    func load() -> PairedDeviceRegistryDocument {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(PairedDeviceRegistryDocument.self, from: data),
              decoded.schemaVersion == 1 else {
            return .empty
        }
        return decoded
    }

    func record(for deviceID: String) -> PairedDeviceRecord? {
        load().devices.first { $0.deviceID == deviceID }
    }

    func upsert(_ record: PairedDeviceRecord) throws {
        var document = load()
        document.devices.removeAll { $0.deviceID == record.deviceID }
        document.devices.append(record)
        document.devices.sort { $0.deviceID < $1.deviceID }
        try AtomicPrivateJSONFile.write(document, to: fileURL, fileManager: fileManager)
    }

    func remove(deviceID: String) throws {
        var document = load()
        document.devices.removeAll { $0.deviceID == deviceID }
        try AtomicPrivateJSONFile.write(document, to: fileURL, fileManager: fileManager)
    }
}

actor BridgeIdentityStore {
    private struct Document: Codable {
        let schemaVersion: Int
        let bridgeID: String

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case bridgeID = "bridge_id"
        }
    }

    private let fileManager: FileManager
    private let fileURL: URL

    init(
        fileManager: FileManager = .default,
        fileURL: URL = SupportPaths.bridgeIdentityFile
    ) {
        self.fileManager = fileManager
        self.fileURL = fileURL
    }

    func bridgeID() throws -> String {
        if let data = try? Data(contentsOf: fileURL),
           let existing = try? JSONDecoder().decode(Document.self, from: data),
           UUID(uuidString: existing.bridgeID) != nil {
            return existing.bridgeID.lowercased()
        }
        let value = UUID().uuidString.lowercased()
        try AtomicPrivateJSONFile.write(
            Document(schemaVersion: 1, bridgeID: value),
            to: fileURL,
            fileManager: fileManager
        )
        return value
    }
}

private enum AtomicPrivateJSONFile {
    static func write<Value: Encodable>(
        _ value: Value,
        to fileURL: URL,
        fileManager: FileManager
    ) throws {
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let data = try JSONEncoder.m2Configuration.encode(value)
        let temporary = directory.appendingPathComponent(".\(fileURL.lastPathComponent).tmp-\(UUID().uuidString)")
        try data.write(to: temporary, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        if fileManager.fileExists(atPath: fileURL.path) {
            _ = try fileManager.replaceItemAt(fileURL, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: fileURL)
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

struct PairingMaterial: Equatable, Sendable {
    let token: String
    let tokenSalt: String
    let tokenHash: String
    let pairingID: String

    static func generate() throws -> PairingMaterial {
        let tokenData = try secureRandomData(count: 32)
        let saltData = try secureRandomData(count: 16)
        let token = tokenData.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let salt = saltData.hexString
        return PairingMaterial(
            token: token,
            tokenSalt: salt,
            tokenHash: tokenHash(salt: saltData, token: token),
            pairingID: UUID().uuidString.lowercased()
        )
    }

    static func tokenHash(salt: Data, token: String) -> String {
        var input = Data("vibestick-pairing-v1\0".utf8)
        input.append(salt)
        input.append(Data(token.utf8))
        return Data(SHA256.hash(data: input)).hexString
    }

    private static func secureRandomData(count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return data
    }
}

enum PairingRecovery {
    static func confirmsCommittedRotation(
        expectedPairingID: String,
        identity: DeviceIdentity
    ) -> Bool {
        identity.pairingID == expectedPairingID
    }
}

struct PairingKeychainMigrationPlan: Equatable, Sendable {
    let previousAccount: String
    let newAccount: String

    static func make(
        deviceID: String,
        pairingID: String,
        existingRecord: PairedDeviceRecord?
    ) -> PairingKeychainMigrationPlan {
        PairingKeychainMigrationPlan(
            previousAccount: existingRecord?.keychainAccount
                ?? "device-token.\(deviceID)",
            newAccount: "device-token.v2.\(deviceID).\(pairingID)"
        )
    }
}

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

actor USBDeviceDetector {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func detect() -> USBDeviceCandidate? {
        let ports = ((try? fileManager.contentsOfDirectory(atPath: "/dev")) ?? [])
            .filter { $0.hasPrefix("cu.usbmodem") }
            .map { "/dev/\($0)" }
            .sorted()
        guard !ports.isEmpty else { return nil }

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
        process.arguments = ["-p", "IOService", "-r", "-c", "AppleUSBACMData", "-l", "-w", "0"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            return USBDeviceDetectionParser.detect(
                ioregOutput: String(decoding: data, as: UTF8.self),
                ports: ports
            )
        } catch {
            return nil
        }
    }
}

actor DeviceSerialClient {
    private struct CommandResponse: Decodable {
        let command: String
        let ok: Bool?
        let identity: DeviceIdentity?
        let error: String?
    }

    private struct PairingPayload: Encodable {
        let schemaVersion = 1
        let pairingID: String
        let bridgeID: String
        let deviceID: String
        let token: String
        let bridgePort: Int
        let fallbackHost: String

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case pairingID = "pairing_id"
            case bridgeID = "bridge_id"
            case deviceID = "device_id"
            case token
            case bridgePort = "bridge_port"
            case fallbackHost = "fallback_host"
        }
    }

    func identify(portPath: String) throws -> DeviceIdentity {
        do {
            return try identifyOnce(portPath: portPath)
        } catch PairingError.responseTimedOut {
            // USB Serial/JTAG may enumerate before the freshly booted firmware task
            // is ready. Retry one complete transaction so the first user-initiated
            // pairing attempt remains reliable without ever writing automatically.
            Thread.sleep(forTimeInterval: 0.35)
            return try identifyOnce(portPath: portPath)
        }
    }

    private func identifyOnce(portPath: String) throws -> DeviceIdentity {
        let response: CommandResponse = try perform(command: "VIBESTICK IDENTIFY\n", portPath: portPath)
        guard response.command == "identify", let identity = response.identity else {
            throw PairingError.unsupportedFirmware
        }
        return identity
    }

    func pair(
        identity: DeviceIdentity,
        material: PairingMaterial,
        bridgeID: String,
        fallbackHost: String,
        portPath: String
    ) throws {
        let payload = PairingPayload(
            pairingID: material.pairingID,
            bridgeID: bridgeID,
            deviceID: identity.deviceID,
            token: material.token,
            bridgePort: 8765,
            fallbackHost: fallbackHost
        )
        let encoded = try JSONEncoder().encode(payload).base64EncodedString()
        let command = "VIBESTICK PAIR \(encoded)\n"
        let response: CommandResponse
        do {
            response = try perform(command: command, portPath: portPath)
        } catch PairingError.responseTimedOut {
            // Retrying the exact same transaction is idempotent: both the
            // random token and transaction UUID are unchanged. This recovers
            // the common case where the device committed successfully but its
            // final USB acknowledgement was lost.
            Thread.sleep(forTimeInterval: 0.2)
            do {
                response = try perform(command: command, portPath: portPath)
            } catch PairingError.responseTimedOut {
                // If the second acknowledgement is also lost, identify returns
                // the non-secret transaction UUID so the Mac can reconcile a
                // committed rotation before deciding whether to roll back its
                // registry and Keychain entry.
                let identityAfterTimeout = try identify(portPath: portPath)
                guard PairingRecovery.confirmsCommittedRotation(
                    expectedPairingID: material.pairingID,
                    identity: identityAfterTimeout
                ) else {
                    throw PairingError.responseTimedOut
                }
                return
            }
        }
        guard response.command == "pair", response.ok == true else {
            throw PairingError.deviceRejected(response.error ?? "设备拒绝了配对配置")
        }
    }

    private func perform<Response: Decodable>(command: String, portPath: String) throws -> Response {
        guard portPath.hasPrefix("/dev/cu.usbmodem") else { throw PairingError.invalidSerialPort }
        try configureSerialPort(portPath)
        let descriptor = Darwin.open(portPath, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard descriptor >= 0 else { throw PairingError.cannotOpenSerialPort }
        defer { Darwin.close(descriptor) }

        try writeAll(Data(command.utf8), descriptor: descriptor)
        let deadline = Date().addingTimeInterval(4)
        var collected = Data()
        while Date() < deadline {
            var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let result = Darwin.poll(&pollDescriptor, 1, 200)
            if result <= 0 { continue }
            var buffer = [UInt8](repeating: 0, count: 1024)
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                collected.append(contentsOf: buffer.prefix(count))
                if let payload = SerialResponseParser.responsePayload(in: collected) {
                    return try JSONDecoder().decode(Response.self, from: payload)
                }
            }
        }
        throw PairingError.responseTimedOut
    }

    private func configureSerialPort(_ portPath: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/stty")
        process.arguments = ["-f", portPath, "115200", "raw", "-echo"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw PairingError.cannotOpenSerialPort }
    }

    private func writeAll(_ data: Data, descriptor: Int32) throws {
        var written = 0
        let deadline = Date().addingTimeInterval(2)
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            while written < data.count {
                let count = Darwin.write(descriptor, base.advanced(by: written), data.count - written)
                if count > 0 {
                    written += count
                } else if count < 0 && (errno == EAGAIN || errno == EINTR) {
                    guard Date() < deadline else { throw PairingError.serialWriteFailed }
                    var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                    _ = Darwin.poll(&pollDescriptor, 1, 100)
                } else {
                    throw PairingError.serialWriteFailed
                }
            }
        }
    }
}

protocol DeviceSerialPairing: Sendable {
    func identify(portPath: String) async throws -> DeviceIdentity
    func pair(
        identity: DeviceIdentity,
        material: PairingMaterial,
        bridgeID: String,
        fallbackHost: String,
        portPath: String
    ) async throws
}

extension DeviceSerialClient: DeviceSerialPairing {}

protocol PairingRegistryStoring: Sendable {
    func record(for deviceID: String) async -> PairedDeviceRecord?
    func upsert(_ record: PairedDeviceRecord) async throws
    func remove(deviceID: String) async throws
}

extension DeviceRegistryStore: PairingRegistryStoring {}

protocol PairingBridgeIdentityStoring: Sendable {
    func bridgeID() async throws -> String
}

extension BridgeIdentityStore: PairingBridgeIdentityStoring {}

protocol PairingTokenStoring: Sendable {
    func write(_ data: Data, account: String) throws
    func delete(account: String) throws
}

extension KeychainStore: PairingTokenStoring {}

actor DevicePairingManager {
    private let serialClient: any DeviceSerialPairing
    private let registryStore: any PairingRegistryStoring
    private let identityStore: any PairingBridgeIdentityStoring
    private let keychainStore: any PairingTokenStoring

    init(
        serialClient: any DeviceSerialPairing = DeviceSerialClient(),
        registryStore: any PairingRegistryStoring = DeviceRegistryStore(),
        identityStore: any PairingBridgeIdentityStoring = BridgeIdentityStore(),
        keychainStore: any PairingTokenStoring = KeychainStore()
    ) {
        self.serialClient = serialClient
        self.registryStore = registryStore
        self.identityStore = identityStore
        self.keychainStore = keychainStore
    }

    func pair(candidate: USBDeviceCandidate, fallbackHost requestedHost: String?) async throws -> DeviceIdentity {
        let identity = try await serialClient.identify(portPath: candidate.portPath)
        guard identity.model == "M5Stack StickS3", identity.protocolVersion >= 2 else {
            throw PairingError.unsupportedFirmware
        }
        let fallbackHost = try ManualBridgeAddressValidator.normalized(requestedHost)
            ?? LocalNetworkAddressResolver.resolve()
            ?? { throw PairingError.noLocalAddress }()
        let material = try PairingMaterial.generate()
        let bridgeID = try await identityStore.bridgeID()
        let oldRecord = await registryStore.record(for: identity.deviceID)
        let keychainPlan = PairingKeychainMigrationPlan.make(
            deviceID: identity.deviceID,
            pairingID: material.pairingID,
            existingRecord: oldRecord
        )
        let record = PairedDeviceRecord(
            deviceID: identity.deviceID,
            name: "StickS3",
            tokenSalt: material.tokenSalt,
            tokenHash: material.tokenHash,
            keychainAccount: keychainPlan.newAccount,
            pairedAt: ISO8601DateFormatter().string(from: Date()),
            firmwareVersion: identity.firmwareVersion,
            revoked: false
        )

        do {
            try await registryStore.upsert(record)
            try keychainStore.write(Data(material.token.utf8), account: keychainPlan.newAccount)
            try await serialClient.pair(
                identity: identity,
                material: material,
                bridgeID: bridgeID,
                fallbackHost: fallbackHost,
                portPath: candidate.portPath
            )
            if keychainPlan.previousAccount != keychainPlan.newAccount {
                // A previous ad-hoc development build may no longer be allowed
                // to decrypt or delete its old item. That token is invalid as
                // soon as the device commits this rotation, so cleanup is safe
                // to treat as best effort without weakening Keychain ACLs.
                try? keychainStore.delete(account: keychainPlan.previousAccount)
            }
            return identity
        } catch {
            if let oldRecord {
                try? await registryStore.upsert(oldRecord)
            } else {
                try? await registryStore.remove(deviceID: identity.deviceID)
            }
            // The old Keychain item was never overwritten. Rollback only
            // removes the newly staged secret and restores the old registry.
            try? keychainStore.delete(account: keychainPlan.newAccount)
            throw error
        }
    }
}

enum LocalNetworkAddressResolver {
    static func resolve() -> String? {
        for interface in ["en0", "en1"] {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/ipconfig")
            process.arguments = ["getifaddr", interface]
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { continue }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { continue }
            let value = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if ManualBridgeAddressValidator.isIPv4(value) { return value }
        }
        return nil
    }
}

enum PairingError: LocalizedError {
    case invalidSerialPort
    case cannotOpenSerialPort
    case serialWriteFailed
    case responseTimedOut
    case unsupportedFirmware
    case deviceRejected(String)
    case invalidManualAddress
    case noLocalAddress

    var errorDescription: String? {
        switch self {
        case .invalidSerialPort: "检测到的串口不属于受支持的 StickS3 USB 连接"
        case .cannotOpenSerialPort: "无法打开 StickS3 串口；请拔插 USB 后重试"
        case .serialWriteFailed: "向 StickS3 发送配对数据失败"
        case .responseTimedOut: "StickS3 没有响应 M2 配对协议；当前稳定固件可能尚未升级"
        case .unsupportedFirmware: "设备已连接，但当前固件不支持 M2 安全配对协议"
        case .deviceRejected(let message): message
        case .invalidManualAddress: "手动 Bridge 地址无效；请填写 IPv4 地址或局域网主机名"
        case .noLocalAddress: "无法确定 Mac 的局域网地址；请在高级设置填写手动地址"
        }
    }
}
