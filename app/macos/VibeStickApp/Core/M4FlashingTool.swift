import Darwin
import Foundation

struct FlashingToolDescriptor: Equatable, Sendable {
    static let maximumArchiveSize: UInt64 = 128 * 1024 * 1024

    static let current = FlashingToolDescriptor(
        identifier: "espressif-esptool",
        displayName: "Espressif esptool",
        version: "5.3.1",
        architecture: "arm64",
        archiveFileName: "esptool-v5.3.1-macos-arm64.tar.gz",
        sourceURL: URL(
            string: "https://github.com/espressif/esptool/releases/download/v5.3.1/esptool-v5.3.1-macos-arm64.tar.gz"
        )!,
        sha256: "f63f7203d88cfe4c17aea34d6cf82769458ce204e49a05816c6384c2d299e6ca",
        size: 61_218_014
    )

    let identifier: String
    let displayName: String
    let version: String
    let architecture: String
    let archiveFileName: String
    let sourceURL: URL
    let sha256: String
    let size: UInt64

    var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    func validate() throws {
        guard sourceURL.scheme?.lowercased() == "https",
              sourceURL.host?.lowercased() == "github.com" else {
            throw FlashingToolError.invalidDescriptor("下载地址必须是 Espressif GitHub 的 HTTPS 地址")
        }
        guard sourceURL.lastPathComponent == archiveFileName,
              !archiveFileName.isEmpty,
              !archiveFileName.contains("/"),
              !archiveFileName.contains("\\"),
              archiveFileName != ".",
              archiveFileName != ".." else {
            throw FlashingToolError.invalidDescriptor("归档文件名不安全")
        }
        guard version.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil else {
            throw FlashingToolError.invalidDescriptor("工具版本格式错误")
        }
        guard architecture == "arm64" else {
            throw FlashingToolError.invalidDescriptor("当前构建只接受 Apple Silicon 工具")
        }
        guard sha256.count == 64,
              sha256.allSatisfy({ $0.isHexDigit }),
              sha256 == sha256.lowercased() else {
            throw FlashingToolError.invalidDescriptor("SHA-256 格式错误")
        }
        guard size > 0, size <= Self.maximumArchiveSize else {
            throw FlashingToolError.invalidDescriptor("归档大小超出允许范围")
        }
    }
}

enum FlashingToolPhase: String, Equatable, Sendable {
    case checking
    case missing
    case ready
    case invalid
    case failed
}

struct FlashingToolSnapshot: Equatable, Sendable {
    let descriptor: FlashingToolDescriptor
    let phase: FlashingToolPhase
    let detail: String
    let archiveURL: URL?

    static func checking(_ descriptor: FlashingToolDescriptor = .current) -> Self {
        Self(
            descriptor: descriptor,
            phase: .checking,
            detail: "正在检查本地工具缓存。",
            archiveURL: nil
        )
    }

    static func failed(
        descriptor: FlashingToolDescriptor = .current,
        detail: String
    ) -> Self {
        Self(descriptor: descriptor, phase: .failed, detail: detail, archiveURL: nil)
    }
}

struct FlashingToolDownloadResponse: Equatable, Sendable {
    let statusCode: Int
    let finalURL: URL
    let expectedContentLength: Int64
    let mimeType: String?
}

protocol FlashingToolDownloading: Sendable {
    func download(from sourceURL: URL, to destinationURL: URL) async throws -> FlashingToolDownloadResponse
}

private final class HTTPSOnlyRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard request.url?.scheme?.lowercased() == "https" else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

actor URLSessionFlashingToolDownloader: FlashingToolDownloading {
    private let session: URLSession
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 600
        self.session = URLSession(
            configuration: configuration,
            delegate: HTTPSOnlyRedirectDelegate(),
            delegateQueue: nil
        )
        self.fileManager = fileManager
    }

    func download(from sourceURL: URL, to destinationURL: URL) async throws -> FlashingToolDownloadResponse {
        var request = URLRequest(url: sourceURL)
        request.httpMethod = "GET"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue("VibeStick-for-Mac-M4-3", forHTTPHeaderField: "User-Agent")

        let (temporaryURL, response) = try await session.download(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              let finalURL = httpResponse.url else {
            throw FlashingToolError.invalidResponse("服务器没有返回 HTTP 响应")
        }
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.copyItem(at: temporaryURL, to: destinationURL)
        return FlashingToolDownloadResponse(
            statusCode: httpResponse.statusCode,
            finalURL: finalURL,
            expectedContentLength: httpResponse.expectedContentLength,
            mimeType: httpResponse.mimeType
        )
    }
}

enum FlashingToolError: LocalizedError {
    case invalidDescriptor(String)
    case invalidResponse(String)
    case unsafeCache(String)
    case sizeMismatch(expected: UInt64, actual: UInt64)
    case digestMismatch
    case fileFailure(String)

    var errorDescription: String? {
        switch self {
        case .invalidDescriptor(let detail):
            "烧录工具清单无效：\(detail)"
        case .invalidResponse(let detail):
            "烧录工具下载未通过安全检查：\(detail)"
        case .unsafeCache(let detail):
            "烧录工具缓存不安全：\(detail)"
        case .sizeMismatch(let expected, let actual):
            "烧录工具大小不符：应为 \(expected) 字节，实际为 \(actual) 字节"
        case .digestMismatch:
            "烧录工具 SHA-256 不符；缓存不会被采用。"
        case .fileFailure(let detail):
            "烧录工具缓存操作失败：\(detail)"
        }
    }
}

actor FlashingToolManager {
    private static let allowedMIMETypes: Set<String> = [
        "application/gzip",
        "application/octet-stream",
        "application/x-gzip",
    ]

    let descriptor: FlashingToolDescriptor
    private let cacheDirectory: URL
    private let transport: any FlashingToolDownloading
    private let fileManager: FileManager

    init(
        descriptor: FlashingToolDescriptor = .current,
        cacheDirectory: URL = SupportPaths.supportDirectory
            .appendingPathComponent("Tools.noindex/esptool/5.3.1/arm64", isDirectory: true),
        transport: any FlashingToolDownloading = URLSessionFlashingToolDownloader(),
        fileManager: FileManager = .default
    ) {
        self.descriptor = descriptor
        self.cacheDirectory = cacheDirectory
        self.transport = transport
        self.fileManager = fileManager
    }

    var archiveURL: URL {
        cacheDirectory.appendingPathComponent(descriptor.archiveFileName)
    }

    func inspect() -> FlashingToolSnapshot {
        do {
            try descriptor.validate()
            guard fileManager.fileExists(atPath: archiveURL.path) else {
                return FlashingToolSnapshot(
                    descriptor: descriptor,
                    phase: .missing,
                    detail: "尚未下载。需要时将从 Espressif 官方 GitHub 获取并校验。",
                    archiveURL: nil
                )
            }
            try validateArchive(at: archiveURL)
            return FlashingToolSnapshot(
                descriptor: descriptor,
                phase: .ready,
                detail: "本地归档的大小与 SHA-256 均已验证；M4-3 不会解包或运行它。",
                archiveURL: archiveURL
            )
        } catch {
            return FlashingToolSnapshot(
                descriptor: descriptor,
                phase: .invalid,
                detail: error.localizedDescription,
                archiveURL: nil
            )
        }
    }

    func downloadAndVerify() async throws -> FlashingToolSnapshot {
        try descriptor.validate()
        try prepareCacheDirectory()

        let stagingURL = cacheDirectory.appendingPathComponent(
            ".\(descriptor.archiveFileName).partial-\(UUID().uuidString)"
        )
        defer { try? fileManager.removeItem(at: stagingURL) }

        let response: FlashingToolDownloadResponse
        do {
            response = try await transport.download(from: descriptor.sourceURL, to: stagingURL)
        } catch let error as FlashingToolError {
            throw error
        } catch {
            throw FlashingToolError.invalidResponse(error.localizedDescription)
        }

        guard response.statusCode == 200 else {
            throw FlashingToolError.invalidResponse("HTTP \(response.statusCode)")
        }
        guard response.finalURL.scheme?.lowercased() == "https" else {
            throw FlashingToolError.invalidResponse("最终下载地址不是 HTTPS")
        }
        guard let mimeType = response.mimeType?.lowercased(),
              Self.allowedMIMETypes.contains(mimeType) else {
            throw FlashingToolError.invalidResponse("内容类型不是受支持的压缩归档")
        }
        if response.expectedContentLength > 0,
           UInt64(response.expectedContentLength) != descriptor.size {
            throw FlashingToolError.sizeMismatch(
                expected: descriptor.size,
                actual: UInt64(response.expectedContentLength)
            )
        }

        try validateArchive(at: stagingURL)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: stagingURL.path
        )
        try atomicallyReplaceArchive(with: stagingURL)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: archiveURL.path
        )

        let snapshot = inspect()
        guard snapshot.phase == .ready else {
            throw FlashingToolError.fileFailure(snapshot.detail)
        }
        return snapshot
    }

    func removeCachedArchive() throws -> FlashingToolSnapshot {
        try descriptor.validate()
        if fileManager.fileExists(atPath: archiveURL.path) {
            try fileManager.removeItem(at: archiveURL)
        }
        return FlashingToolSnapshot(
            descriptor: descriptor,
            phase: .missing,
            detail: "本地烧录工具缓存已移除；后台组件和设备固件均未改变。",
            archiveURL: nil
        )
    }

    private func prepareCacheDirectory() throws {
        do {
            try fileManager.createDirectory(
                at: cacheDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: cacheDirectory.path
            )
        } catch {
            throw FlashingToolError.fileFailure(error.localizedDescription)
        }
    }

    private func validateArchive(at url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true, values.isRegularFile == true else {
            throw FlashingToolError.unsafeCache("缓存必须是普通文件且不能是符号链接")
        }
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let actualSize = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        guard actualSize == descriptor.size else {
            throw FlashingToolError.sizeMismatch(expected: descriptor.size, actual: actualSize)
        }
        let digest = try RuntimePayloadDigest.sha256(of: url)
        guard digest == descriptor.sha256 else {
            throw FlashingToolError.digestMismatch
        }
    }

    private func atomicallyReplaceArchive(with stagingURL: URL) throws {
        let result = stagingURL.path.withCString { stagingPath in
            archiveURL.path.withCString { archivePath in
                Darwin.rename(stagingPath, archivePath)
            }
        }
        guard result == 0 else {
            throw FlashingToolError.fileFailure(String(cString: strerror(errno)))
        }
    }
}
