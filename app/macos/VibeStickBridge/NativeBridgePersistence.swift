import Darwin
import Foundation

enum NativeBridgePersistenceError: Error {
    case invalidPath
    case invalidJSON
    case oversizedFile
    case systemCall(String, Int32)
}

enum NativeBridgeSecureFile {
    static func writeDataAtomically(_ data: Data, to url: URL) throws {
        try writeAtomically(data, to: url)
    }

    static func readPrefix(at url: URL, maximumBytes: Int) throws -> Data? {
        try readSlice(at: url, maximumBytes: maximumBytes, fromEnd: false)
    }

    static func readTail(at url: URL, maximumBytes: Int) throws -> Data? {
        try readSlice(at: url, maximumBytes: maximumBytes, fromEnd: true)
    }

    static func readData(at url: URL, maximumBytes: Int) throws -> Data? {
        guard url.isFileURL, maximumBytes >= 0 else {
            throw NativeBridgePersistenceError.invalidPath
        }
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw NativeBridgePersistenceError.systemCall("open", errno)
        }
        defer { Darwin.close(descriptor) }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw NativeBridgePersistenceError.systemCall("fstat", errno)
        }
        guard (metadata.st_mode & S_IFMT) == S_IFREG else {
            throw NativeBridgePersistenceError.invalidPath
        }
        guard metadata.st_size >= 0, metadata.st_size <= maximumBytes else {
            throw NativeBridgePersistenceError.oversizedFile
        }

        var result = Data()
        result.reserveCapacity(Int(metadata.st_size))
        var buffer = [UInt8](repeating: 0, count: min(16_384, max(1, maximumBytes + 1)))
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw NativeBridgePersistenceError.systemCall("read", errno)
            }
            guard result.count + count <= maximumBytes else {
                throw NativeBridgePersistenceError.oversizedFile
            }
            result.append(buffer, count: count)
        }
        return result
    }

    private static func readSlice(
        at url: URL,
        maximumBytes: Int,
        fromEnd: Bool
    ) throws -> Data? {
        guard url.isFileURL, maximumBytes >= 0 else {
            throw NativeBridgePersistenceError.invalidPath
        }
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw NativeBridgePersistenceError.systemCall("open", errno)
        }
        defer { Darwin.close(descriptor) }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw NativeBridgePersistenceError.systemCall("fstat", errno)
        }
        guard (metadata.st_mode & S_IFMT) == S_IFREG, metadata.st_size >= 0 else {
            throw NativeBridgePersistenceError.invalidPath
        }
        let count = min(Int64(maximumBytes), metadata.st_size)
        if fromEnd, count > 0,
           lseek(descriptor, metadata.st_size - count, SEEK_SET) < 0 {
            throw NativeBridgePersistenceError.systemCall("lseek", errno)
        }
        var result = Data()
        result.reserveCapacity(Int(count))
        var remaining = Int(count)
        var buffer = [UInt8](repeating: 0, count: min(16_384, max(1, remaining)))
        while remaining > 0 {
            let requested = min(remaining, buffer.count)
            let bytesRead = Darwin.read(descriptor, &buffer, requested)
            if bytesRead == 0 { break }
            if bytesRead < 0 {
                if errno == EINTR { continue }
                throw NativeBridgePersistenceError.systemCall("read", errno)
            }
            result.append(buffer, count: bytesRead)
            remaining -= bytesRead
        }
        return result
    }

    static func writeJSONAtomically(_ object: [String: Any], to url: URL) throws {
        var data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
        data.append(0x0A)
        try writeAtomically(data, to: url)
    }

    private static func writeAtomically(_ data: Data, to url: URL) throws {
        guard url.isFileURL else { throw NativeBridgePersistenceError.invalidPath }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: directory.path
        )

        var existing = stat()
        if url.path.withCString({ lstat($0, &existing) }) == 0,
           (existing.st_mode & S_IFMT) == S_IFLNK {
            throw NativeBridgePersistenceError.invalidPath
        }
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        let descriptor = temporary.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        }
        guard descriptor >= 0 else {
            throw NativeBridgePersistenceError.systemCall("open", errno)
        }

        var shouldRemoveTemporary = true
        defer {
            Darwin.close(descriptor)
            if shouldRemoveTemporary {
                try? FileManager.default.removeItem(at: temporary)
            }
        }
        try data.withUnsafeBytes { rawBuffer in
            guard var pointer = rawBuffer.baseAddress else { return }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let written = Darwin.write(descriptor, pointer, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw NativeBridgePersistenceError.systemCall("write", errno)
                }
                remaining -= written
                pointer = pointer.advanced(by: written)
            }
        }
        guard fsync(descriptor) == 0 else {
            throw NativeBridgePersistenceError.systemCall("fsync", errno)
        }
        guard temporary.path.withCString({ temporaryPath in
            url.path.withCString { finalPath in
                Darwin.rename(temporaryPath, finalPath)
            }
        }) == 0 else {
            throw NativeBridgePersistenceError.systemCall("rename", errno)
        }
        shouldRemoveTemporary = false
        guard chmod(url.path, 0o600) == 0 else {
            throw NativeBridgePersistenceError.systemCall("chmod", errno)
        }
    }
}

struct NativePairedDevice: Equatable {
    let deviceID: String
    let name: String
    let tokenSalt: String
    let tokenHash: String
    let pairedAt: String
    let firmwareVersion: String
    let revoked: Bool
}

final class NativePairedDeviceRegistry {
    static let schemaVersion = 1
    static let minimumTokenLength = 32
    private static let maximumRegistryBytes = 1_048_576

    private let path: URL

    init(path: URL) {
        self.path = path
    }

    func devices() -> [NativePairedDevice] {
        guard let data = try? NativeBridgeSecureFile.readData(
            at: path,
            maximumBytes: Self.maximumRegistryBytes
        ),
        let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        integer(payload["schema_version"]) == Self.schemaVersion,
        let rawDevices = payload["devices"] as? [Any] else {
            return []
        }
        return rawDevices.compactMap(Self.device(from:))
    }

    func find(deviceID: String) -> NativePairedDevice? {
        guard Self.validDeviceID(deviceID) else { return nil }
        return devices().first { $0.deviceID == deviceID }
    }

    func authenticate(deviceID: String, token: String) -> Bool {
        guard token.count >= Self.minimumTokenLength,
              let device = find(deviceID: deviceID),
              !device.revoked else {
            return false
        }
        let actual = NativeBridgeSecurity.pairingTokenHash(
            saltHex: device.tokenSalt,
            token: token
        )
        return NativeBridgeSecurity.constantTimeEqual(actual, device.tokenHash)
    }

    static func validDeviceID(_ value: String) -> Bool {
        guard (6...64).contains(value.utf8.count),
              let first = value.unicodeScalars.first,
              CharacterSet.alphanumerics.contains(first) else {
            return false
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._:-"))
        return value.unicodeScalars.allSatisfy { allowed.contains($0) && $0.isASCII }
    }

    private static func device(from value: Any) -> NativePairedDevice? {
        guard let object = value as? [String: Any] else { return nil }
        let deviceID = string(object["device_id"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let salt = string(object["token_salt"])
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hash = string(object["token_hash"])
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard validDeviceID(deviceID),
              salt.count == 32, isLowerHex(salt),
              hash.count == 64, isLowerHex(hash) else {
            return nil
        }
        return NativePairedDevice(
            deviceID: deviceID,
            name: String((string(object["name"]).isEmpty ? "StickS3" : string(object["name"])).prefix(64)),
            tokenSalt: salt,
            tokenHash: hash,
            pairedAt: String(string(object["paired_at"]).prefix(64)),
            firmwareVersion: String(string(object["firmware_version"]).prefix(32)),
            revoked: jsonTruth(object["revoked"], defaultValue: false)
        )
    }
}

final class NativeDeviceConfigurationStore {
    static let schemaVersion = 1
    static let maximumBytes = 16_384
    private static let allowedModules: Set<String> = ["codex", "claude", "connection"]
    private static let doublePressActions: Set<String> = ["refresh_quota", "show_status", "home", "toggle_mute"]
    private static let sidePressActions: Set<String> = ["next_page", "none"]

    private let path: URL
    private let managedProjectPresentation: [String: Any]?

    init(path: URL, managedProjectPresentation: [String: Any]? = nil) {
        self.path = path
        self.managedProjectPresentation = managedProjectPresentation
    }

    func current() -> [String: Any] {
        let configuration: [String: Any]
        if let data = try? NativeBridgeSecureFile.readData(at: path, maximumBytes: Self.maximumBytes),
           let value = try? JSONSerialization.jsonObject(with: data) {
            configuration = Self.normalize(value)
        } else {
            configuration = Self.defaultConfiguration()
        }
        guard let managedProjectPresentation else { return configuration }
        let managed = Self.normalize([
            "schema_version": Self.schemaVersion,
            "project": [
                "visible": managedProjectPresentation["showProjectName"] as Any,
                "name": managedProjectPresentation["projectName"] as Any,
            ],
        ])["project"] as? [String: Any] ?? [:]
        var result = configuration
        result["project"] = managed
        return result
    }

    static func defaultConfiguration() -> [String: Any] {
        [
            "schema_version": schemaVersion,
            "revision": 0,
            "modules": ["codex", "connection"],
            "default_page": "codex",
            "project": ["visible": true, "name": ""],
            "buttons": ["front_double": "refresh_quota", "side_single": "next_page"],
        ]
    }

    static func normalize(_ value: Any) -> [String: Any] {
        guard let object = value as? [String: Any],
              integer(object["schema_version"]) == schemaVersion else {
            return defaultConfiguration()
        }

        let revision = max(0, integer(object["revision"]) ?? 0)
        var modules: [String] = []
        for case let module as String in object["modules"] as? [Any] ?? []
        where allowedModules.contains(module) && !modules.contains(module) {
            modules.append(module)
        }
        if !modules.contains("codex") { modules.insert("codex", at: 0) }
        if !modules.contains("connection") { modules.append("connection") }

        let requestedPage = object["default_page"] as? String ?? ""
        let defaultPage = modules.contains(requestedPage) ? requestedPage : "codex"
        let project = object["project"] as? [String: Any] ?? [:]
        var projectName = (project["name"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        projectName = String(projectName.prefix(18))
        while projectName.utf8.count > 39 { projectName.removeLast() }

        let buttons = object["buttons"] as? [String: Any] ?? [:]
        let requestedDouble = buttons["front_double"] as? String ?? ""
        let requestedSide = buttons["side_single"] as? String ?? ""
        return [
            "schema_version": schemaVersion,
            "revision": revision,
            "modules": modules,
            "default_page": defaultPage,
            "project": [
                "visible": jsonTruth(project["visible"], defaultValue: true),
                "name": projectName,
            ],
            "buttons": [
                "front_double": doublePressActions.contains(requestedDouble) ? requestedDouble : "refresh_quota",
                "side_single": sidePressActions.contains(requestedSide) ? requestedSide : "next_page",
            ],
        ]
    }
}

final class NativeBridgeIdentityStore {
    static let schemaVersion = 1
    private let path: URL
    private let lock = NSLock()

    init(path: URL) {
        self.path = path
    }

    func bridgeID() throws -> String {
        lock.lock()
        defer { lock.unlock() }
        if let data = try? NativeBridgeSecureFile.readData(at: path, maximumBytes: 4_096),
           let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let rawID = payload["bridge_id"] as? String,
           let existing = UUID(uuidString: rawID) {
            return existing.uuidString.lowercased()
        }
        let identifier = UUID().uuidString.lowercased()
        try NativeBridgeSecureFile.writeJSONAtomically([
            "schema_version": Self.schemaVersion,
            "bridge_id": identifier,
        ], to: path)
        return identifier
    }
}

private func integer(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber,
          CFGetTypeID(number) != CFBooleanGetTypeID(),
          number.doubleValue.rounded() == number.doubleValue else {
        return nil
    }
    return number.intValue
}

private func string(_ value: Any?) -> String {
    if value == nil || value is NSNull { return "" }
    return String(describing: value!)
}

private func jsonTruth(_ value: Any?, defaultValue: Bool) -> Bool {
    guard let value, !(value is NSNull) else { return defaultValue }
    if let boolean = value as? Bool { return boolean }
    if let number = value as? NSNumber { return number.doubleValue != 0 }
    if let string = value as? String { return !string.isEmpty }
    if let array = value as? [Any] { return !array.isEmpty }
    if let object = value as? [String: Any] { return !object.isEmpty }
    return true
}

private func isLowerHex(_ value: String) -> Bool {
    value.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
}
