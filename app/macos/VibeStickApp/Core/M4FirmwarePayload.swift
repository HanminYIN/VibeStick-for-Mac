import Foundation

struct FirmwarePayloadFile: Codable, Equatable, Sendable {
    let mode: UInt16
    let offset: UInt64
    let path: String
    let sha256: String
    let size: UInt64
}

struct FirmwareFlashGeometry: Codable, Equatable, Sendable {
    let frequency: String
    let mode: String
    let size: UInt64
}

struct FirmwarePreservedRange: Codable, Equatable, Sendable {
    let name: String
    let start: UInt64
    let endExclusive: UInt64
}

struct FirmwareSourceIdentity: Codable, Equatable, Sendable {
    let digest: String
    let revision: String
}

struct FirmwarePayloadManifest: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let board: String
    let files: [FirmwarePayloadFile]
    let flash: FirmwareFlashGeometry
    let payloadVersion: String
    let preservedRanges: [FirmwarePreservedRange]
    let schemaVersion: Int
    let source: FirmwareSourceIdentity
    let target: String
}

enum FirmwarePayloadError: LocalizedError {
    case unavailable
    case invalidManifest(String)
    case unsafeFile(String)
    case mismatch(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "安装包内没有找到经过校验的 StickS3 固件载荷。"
        case .invalidManifest(let detail):
            "固件清单无效：\(detail)"
        case .unsafeFile(let detail):
            "固件载荷包含不安全文件：\(detail)"
        case .mismatch(let detail):
            "固件载荷完整性校验失败：\(detail)"
        }
    }
}

enum FirmwarePayloadValidator {
    static let manifestName = "manifest-v1.json"
    static let flashSize: UInt64 = 8 * 1024 * 1024
    static let requiredOffsets: [String: UInt64] = [
        "bootloader.bin": 0x0000,
        "partition-table.bin": 0x8000,
        "vibe-stick.bin": 0x10000,
    ]
    static let preservedNVS = FirmwarePreservedRange(
        name: "nvs",
        start: 0x9000,
        endExclusive: 0xf000
    )

    static func validate(
        root: URL,
        fileManager: FileManager = .default
    ) throws -> FirmwarePayloadManifest {
        let manifestURL = root.appendingPathComponent(manifestName)
        let manifestValues = try? manifestURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard manifestValues?.isRegularFile == true, manifestValues?.isSymbolicLink != true else {
            throw FirmwarePayloadError.unavailable
        }

        let manifest: FirmwarePayloadManifest
        do {
            manifest = try JSONDecoder().decode(
                FirmwarePayloadManifest.self,
                from: Data(contentsOf: manifestURL)
            )
        } catch {
            throw FirmwarePayloadError.invalidManifest(error.localizedDescription)
        }
        guard manifest.schemaVersion == FirmwarePayloadManifest.currentSchemaVersion else {
            throw FirmwarePayloadError.invalidManifest("不支持 schema \(manifest.schemaVersion)")
        }
        guard manifest.target == "esp32s3", manifest.board == "M5Stack StickS3" else {
            throw FirmwarePayloadError.invalidManifest("目标设备不匹配")
        }
        guard manifest.flash == FirmwareFlashGeometry(frequency: "80m", mode: "dio", size: flashSize) else {
            throw FirmwarePayloadError.invalidManifest("Flash 参数不匹配")
        }
        guard manifest.preservedRanges == [preservedNVS] else {
            throw FirmwarePayloadError.invalidManifest("NVS 保留范围不匹配")
        }
        guard !manifest.payloadVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              isLowercaseHex(manifest.source.revision, count: 40),
              isLowercaseHex(manifest.source.digest, count: 64) else {
            throw FirmwarePayloadError.invalidManifest("版本或源码身份无效")
        }

        var declared = Set<String>()
        var ranges: [(start: UInt64, end: UInt64, path: String)] = []
        for entry in manifest.files {
            guard requiredOffsets[entry.path] == entry.offset,
                  declared.insert(entry.path).inserted else {
                throw FirmwarePayloadError.invalidManifest("文件或偏移不匹配：\(entry.path)")
            }
            guard entry.mode == 0o644, entry.size > 0,
                  entry.offset <= flashSize,
                  entry.size <= flashSize - entry.offset,
                  isLowercaseHex(entry.sha256, count: 64) else {
                throw FirmwarePayloadError.invalidManifest("文件元数据无效：\(entry.path)")
            }
            let end = entry.offset + entry.size
            guard !(entry.offset < preservedNVS.endExclusive && end > preservedNVS.start) else {
                throw FirmwarePayloadError.invalidManifest("文件覆盖 NVS：\(entry.path)")
            }
            ranges.append((entry.offset, end, entry.path))
        }
        guard declared == Set(requiredOffsets.keys) else {
            throw FirmwarePayloadError.invalidManifest("固件文件集合不完整")
        }
        ranges.sort { $0.start < $1.start }
        for index in 1..<ranges.count where ranges[index - 1].end > ranges[index].start {
            throw FirmwarePayloadError.invalidManifest(
                "Flash 范围重叠：\(ranges[index - 1].path) 与 \(ranges[index].path)"
            )
        }

        let contents: [URL]
        do {
            contents = try fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: []
            )
        } catch {
            throw FirmwarePayloadError.unavailable
        }
        var actual = Set<String>()
        for url in contents where url.lastPathComponent != manifestName {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw FirmwarePayloadError.unsafeFile(url.lastPathComponent)
            }
            actual.insert(url.lastPathComponent)
        }
        guard actual == declared else {
            throw FirmwarePayloadError.mismatch("实际文件集合与清单不一致")
        }

        for entry in manifest.files {
            let url = root.appendingPathComponent(entry.path)
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            let mode = (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
            guard size == entry.size, mode == entry.mode else {
                throw FirmwarePayloadError.mismatch("\(entry.path) 的大小或权限不符")
            }
            guard try RuntimePayloadDigest.sha256(of: url) == entry.sha256 else {
                throw FirmwarePayloadError.mismatch("\(entry.path) 的 SHA-256 不符")
            }
        }
        return manifest
    }

    private static func isLowercaseHex(_ value: String, count: Int) -> Bool {
        value.count == count
            && value == value.lowercased()
            && value.allSatisfy(\.isHexDigit)
    }
}
