import Darwin
import Dispatch
import Foundation
import Security

struct FlashingToolPayloadFile: Equatable, Sendable {
    let path: String
    let size: UInt64
    let sha256: String
    let executable: Bool
    let signingIdentifier: String?
}

struct FlashingToolPayloadDescriptor: Equatable, Sendable {
    let archiveRootDirectory: String
    let signingTeamIdentifier: String
    let files: [FlashingToolPayloadFile]

    var archiveEntries: [String] {
        ["\(archiveRootDirectory)/"] + files.map { "\(archiveRootDirectory)/\($0.path)" }
    }

    var primaryExecutable: FlashingToolPayloadFile? {
        files.first { $0.path == "esptool" && $0.executable }
    }

    func validate() throws {
        guard isSafeComponent(archiveRootDirectory) else {
            throw FlashingToolError.invalidDescriptor("归档顶层目录不安全")
        }
        guard signingTeamIdentifier.range(
            of: #"^[A-Z0-9]{10}$"#,
            options: .regularExpression
        ) != nil else {
            throw FlashingToolError.invalidDescriptor("签名团队标识格式错误")
        }
        guard !files.isEmpty, primaryExecutable != nil else {
            throw FlashingToolError.invalidDescriptor("工具文件清单不完整")
        }

        var seen = Set<String>()
        for file in files {
            guard isSafeComponent(file.path), seen.insert(file.path).inserted else {
                throw FlashingToolError.invalidDescriptor("工具文件路径不安全或重复")
            }
            guard file.size > 0,
                  file.sha256.count == 64,
                  file.sha256.allSatisfy({ $0.isHexDigit }),
                  file.sha256 == file.sha256.lowercased() else {
                throw FlashingToolError.invalidDescriptor("工具文件大小或 SHA-256 无效")
            }
            if file.executable {
                guard let signingIdentifier = file.signingIdentifier,
                      isSafeComponent(signingIdentifier) else {
                    throw FlashingToolError.invalidDescriptor("可执行文件签名标识无效")
                }
            } else if file.signingIdentifier != nil {
                throw FlashingToolError.invalidDescriptor("普通文件不应声明签名标识")
            }
        }
    }

    private func isSafeComponent(_ value: String) -> Bool {
        !value.isEmpty
            && value != "."
            && value != ".."
            && !value.contains("/")
            && !value.contains("\\")
            && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }
}

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
        size: 61_218_014,
        payload: FlashingToolPayloadDescriptor(
            archiveRootDirectory: "esptool-macos-arm64",
            signingTeamIdentifier: "QWXF6GB4AV",
            files: [
                FlashingToolPayloadFile(
                    path: "espefuse",
                    size: 18_009_888,
                    sha256: "6d3467b0ec660b383b7441a25d3687ea587cfb76f7ea695efd56035e8308c72c",
                    executable: true,
                    signingIdentifier: "espefuse"
                ),
                FlashingToolPayloadFile(
                    path: "README.md",
                    size: 1_935,
                    sha256: "fcff74336b1463a7da838cae3b21b31bd4f4af87e46d07474973ca603b1b6ab3",
                    executable: false,
                    signingIdentifier: nil
                ),
                FlashingToolPayloadFile(
                    path: "LICENSE",
                    size: 18_092,
                    sha256: "8177f97513213526df2cf6184d8ff986c675afb514d4e68a404010521b880643",
                    executable: false,
                    signingIdentifier: nil
                ),
                FlashingToolPayloadFile(
                    path: "esptool",
                    size: 13_400_752,
                    sha256: "cb6109272050558582626b676b2bbf3737ed126df5faef373c5c66fae9c27097",
                    executable: true,
                    signingIdentifier: "esptool"
                ),
                FlashingToolPayloadFile(
                    path: "esp_rfc2217_server",
                    size: 13_262_768,
                    sha256: "425bc535f35c28b6be572bf098f18cc91ccc73bf004dcca8f7659d9937212331",
                    executable: true,
                    signingIdentifier: "esp_rfc2217_server"
                ),
                FlashingToolPayloadFile(
                    path: "espsecure",
                    size: 17_285_360,
                    sha256: "eb6260ccf82bdafa196c8be0178c84b733a22fb286639b504fbff1a9eed8ff0a",
                    executable: true,
                    signingIdentifier: "espsecure"
                ),
            ]
        )
    )

    let identifier: String
    let displayName: String
    let version: String
    let architecture: String
    let archiveFileName: String
    let sourceURL: URL
    let sha256: String
    let size: UInt64
    let payload: FlashingToolPayloadDescriptor

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
        try payload.validate()
    }
}

enum FlashingToolPhase: String, Equatable, Sendable {
    case checking
    case missing
    case archiveReady
    case ready
    case invalid
    case failed
}

struct FlashingToolSnapshot: Equatable, Sendable {
    let descriptor: FlashingToolDescriptor
    let phase: FlashingToolPhase
    let detail: String
    let archiveURL: URL?
    let executableURL: URL?

    static func checking(_ descriptor: FlashingToolDescriptor = .current) -> Self {
        Self(
            descriptor: descriptor,
            phase: .checking,
            detail: "正在检查本地工具缓存。",
            archiveURL: nil,
            executableURL: nil
        )
    }

    static func failed(
        descriptor: FlashingToolDescriptor = .current,
        detail: String
    ) -> Self {
        Self(
            descriptor: descriptor,
            phase: .failed,
            detail: detail,
            archiveURL: nil,
            executableURL: nil
        )
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

protocol FlashingToolExtracting: Sendable {
    func extract(
        archiveURL: URL,
        to destinationURL: URL,
        expectedEntries: [String]
    ) throws
}

struct SystemTarFlashingToolExtractor: FlashingToolExtracting {
    func extract(
        archiveURL: URL,
        to destinationURL: URL,
        expectedEntries: [String]
    ) throws {
        let names = try FlashingToolProcess.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["-tf", archiveURL.path],
            timeout: 20
        )
        let verbose = try FlashingToolProcess.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["-tvf", archiveURL.path],
            timeout: 20
        )
        try Self.validateArchiveListing(
            names: names.standardOutput,
            verbose: verbose.standardOutput,
            expectedEntries: expectedEntries
        )

        let extraction = try FlashingToolProcess.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: [
                "-xzf", archiveURL.path,
                "-C", destinationURL.path,
                "--strip-components", "1",
                "--no-same-owner",
                "--no-same-permissions",
            ],
            timeout: 120
        )
        guard extraction.standardOutput.isEmpty else {
            throw FlashingToolError.extractionFailure("解包产生了意外标准输出")
        }
    }

    static func validateArchiveListing(
        names: String,
        verbose: String,
        expectedEntries: [String]
    ) throws {
        let listedNames = normalizedLines(names)
        let verboseLines = normalizedLines(verbose)
        guard listedNames == expectedEntries,
              Set(listedNames).count == listedNames.count else {
            throw FlashingToolError.extractionFailure("归档条目、顺序或路径不符合固定清单")
        }
        guard verboseLines.count == expectedEntries.count else {
            throw FlashingToolError.extractionFailure("归档类型清单不完整")
        }
        for (index, line) in verboseLines.enumerated() {
            let expectedType: Character = index == 0 ? "d" : "-"
            guard line.first == expectedType else {
                throw FlashingToolError.extractionFailure("归档包含链接或非普通文件")
            }
        }
    }

    private static func normalizedLines(_ value: String) -> [String] {
        var lines = value.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" {
            lines.removeLast()
        }
        return lines
    }
}

protocol FlashingToolExecutableValidating: Sendable {
    func validate(
        executableURL: URL,
        teamIdentifier: String,
        signingIdentifier: String
    ) throws
}

struct AppleSiliconFlashingToolExecutableValidator: FlashingToolExecutableValidating {
    func validate(
        executableURL: URL,
        teamIdentifier: String,
        signingIdentifier: String
    ) throws {
        let header = try Data(contentsOf: executableURL, options: [.mappedIfSafe]).prefix(8)
        guard header.count == 8 else {
            throw FlashingToolError.signatureMismatch("可执行文件头不完整")
        }
        let bytes = Array(header)
        let magic = littleEndianUInt32(bytes[0...3])
        let cpuType = littleEndianUInt32(bytes[4...7])
        guard magic == 0xfeedfacf, cpuType == 0x0100000c else {
            throw FlashingToolError.signatureMismatch("可执行文件不是纯 Apple Silicon Mach-O")
        }

        var staticCode: SecStaticCode?
        var status = SecStaticCodeCreateWithPath(
            executableURL as CFURL,
            SecCSFlags(rawValue: 0),
            &staticCode
        )
        guard status == errSecSuccess, let staticCode else {
            throw FlashingToolError.signatureMismatch("无法读取代码签名（\(status)）")
        }

        let requirementText = "anchor apple generic and certificate leaf[subject.OU] = \"\(teamIdentifier)\" and identifier \"\(signingIdentifier)\""
        var requirement: SecRequirement?
        status = SecRequirementCreateWithString(
            requirementText as CFString,
            SecCSFlags(rawValue: 0),
            &requirement
        )
        guard status == errSecSuccess, let requirement else {
            throw FlashingToolError.signatureMismatch("无法建立签名要求（\(status)）")
        }

        status = SecStaticCodeCheckValidity(
            staticCode,
            SecCSFlags(rawValue: kSecCSStrictValidate),
            requirement
        )
        guard status == errSecSuccess else {
            throw FlashingToolError.signatureMismatch("Espressif Developer ID 签名无效（\(status)）")
        }
    }

    private func littleEndianUInt32(_ bytes: ArraySlice<UInt8>) -> UInt32 {
        bytes.enumerated().reduce(0) { partial, element in
            partial | (UInt32(element.element) << UInt32(element.offset * 8))
        }
    }
}

protocol FlashingToolVersionChecking: Sendable {
    func version(executableURL: URL, expectedVersion: String) throws -> String
}

struct OfflineFlashingToolVersionChecker: FlashingToolVersionChecking {
    func version(executableURL: URL, expectedVersion: String) throws -> String {
        let result = try FlashingToolProcess.run(
            executableURL: executableURL,
            arguments: ["version"],
            timeout: 30
        )
        let lines = result.standardOutput
            .split(separator: "\n")
            .map(String.init)
        guard lines.contains("esptool v\(expectedVersion)"),
              lines.last == expectedVersion else {
            throw FlashingToolError.versionMismatch
        }
        return expectedVersion
    }
}

private struct FlashingToolProcessResult {
    let standardOutput: String
}

private enum FlashingToolProcess {
    static func run(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval
    ) throws -> FlashingToolProcessResult {
        let process = Process()
        let output = Pipe()
        let errorOutput = Pipe()
        let completion = DispatchSemaphore(value: 0)
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errorOutput
        process.environment = [
            "LC_ALL": "C",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": FileManager.default.temporaryDirectory.path,
        ]
        process.terminationHandler = { _ in completion.signal() }

        do {
            try process.run()
        } catch {
            throw FlashingToolError.fileFailure(error.localizedDescription)
        }
        if completion.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if completion.wait(timeout: .now() + 2) == .timedOut {
                Darwin.kill(process.processIdentifier, SIGKILL)
                _ = completion.wait(timeout: .now() + 2)
            }
            throw FlashingToolError.fileFailure("离线工具检查超时")
        }

        let standardOutput = output.fileHandleForReading.readDataToEndOfFile()
        let standardError = errorOutput.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let detail = String(data: standardError, encoding: .utf8) ?? "退出码 \(process.terminationStatus)"
            throw FlashingToolError.fileFailure(detail.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard let decodedOutput = String(data: standardOutput, encoding: .utf8),
              String(data: standardError, encoding: .utf8) != nil else {
            throw FlashingToolError.fileFailure("工具输出不是 UTF-8")
        }
        return FlashingToolProcessResult(standardOutput: decodedOutput)
    }
}

enum FlashingToolError: LocalizedError {
    case invalidDescriptor(String)
    case invalidResponse(String)
    case unsafeCache(String)
    case sizeMismatch(expected: UInt64, actual: UInt64)
    case digestMismatch
    case extractionFailure(String)
    case payloadMismatch(String)
    case signatureMismatch(String)
    case versionMismatch
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
        case .extractionFailure(let detail):
            "烧录工具归档不能安全解包：\(detail)"
        case .payloadMismatch(let detail):
            "烧录工具文件未通过校验：\(detail)"
        case .signatureMismatch(let detail):
            "烧录工具签名或架构未通过校验：\(detail)"
        case .versionMismatch:
            "烧录工具自报版本与固定版本不符。"
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
    private let extractor: any FlashingToolExtracting
    private let executableValidator: any FlashingToolExecutableValidating
    private let versionChecker: any FlashingToolVersionChecking
    private let fileManager: FileManager

    init(
        descriptor: FlashingToolDescriptor = .current,
        cacheDirectory: URL = SupportPaths.supportDirectory
            .appendingPathComponent("Tools.noindex/esptool/5.3.1/arm64", isDirectory: true),
        transport: any FlashingToolDownloading = URLSessionFlashingToolDownloader(),
        extractor: any FlashingToolExtracting = SystemTarFlashingToolExtractor(),
        executableValidator: any FlashingToolExecutableValidating = AppleSiliconFlashingToolExecutableValidator(),
        versionChecker: any FlashingToolVersionChecking = OfflineFlashingToolVersionChecker(),
        fileManager: FileManager = .default
    ) {
        self.descriptor = descriptor
        self.cacheDirectory = cacheDirectory
        self.transport = transport
        self.extractor = extractor
        self.executableValidator = executableValidator
        self.versionChecker = versionChecker
        self.fileManager = fileManager
    }

    var archiveURL: URL {
        cacheDirectory.appendingPathComponent(descriptor.archiveFileName)
    }

    var preparedDirectoryURL: URL {
        cacheDirectory.appendingPathComponent("Prepared.noindex", isDirectory: true)
    }

    var executableURL: URL {
        preparedDirectoryURL.appendingPathComponent("esptool")
    }

    func inspect() -> FlashingToolSnapshot {
        do {
            try descriptor.validate()
            guard fileManager.fileExists(atPath: archiveURL.path) else {
                return FlashingToolSnapshot(
                    descriptor: descriptor,
                    phase: .missing,
                    detail: "尚未下载。需要时将从 Espressif 官方 GitHub 获取并校验。",
                    archiveURL: nil,
                    executableURL: nil
                )
            }
            try validateArchive(at: archiveURL)
            guard fileManager.fileExists(atPath: preparedDirectoryURL.path) else {
                return FlashingToolSnapshot(
                    descriptor: descriptor,
                    phase: .archiveReady,
                    detail: "本地归档的大小与 SHA-256 均已验证；尚未解包工具。",
                    archiveURL: archiveURL,
                    executableURL: nil
                )
            }
            try validatePreparedDirectory(
                at: preparedDirectoryURL,
                validateExecutableIdentity: true,
                requireSecureModes: true
            )
            return FlashingToolSnapshot(
                descriptor: descriptor,
                phase: .ready,
                detail: "固定归档、内部文件、Apple Silicon 架构与 Espressif 签名均已验证。",
                archiveURL: archiveURL,
                executableURL: executableURL
            )
        } catch {
            return FlashingToolSnapshot(
                descriptor: descriptor,
                phase: .invalid,
                detail: error.localizedDescription,
                archiveURL: nil,
                executableURL: nil
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
        guard snapshot.phase == .archiveReady || snapshot.phase == .ready else {
            throw FlashingToolError.fileFailure(snapshot.detail)
        }
        return snapshot
    }

    func prepareAndVerify() throws -> FlashingToolSnapshot {
        try descriptor.validate()
        try prepareCacheDirectory()
        try validateArchive(at: archiveURL)

        let stagingURL = cacheDirectory.appendingPathComponent(
            ".Prepared.noindex.partial-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: stagingURL) }
        do {
            try fileManager.createDirectory(
                at: stagingURL,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            try extractor.extract(
                archiveURL: archiveURL,
                to: stagingURL,
                expectedEntries: descriptor.payload.archiveEntries
            )
            try validatePreparedDirectory(
                at: stagingURL,
                validateExecutableIdentity: false,
                requireSecureModes: false
            )
            try normalizePreparedPermissions(at: stagingURL)
            try validatePreparedDirectory(
                at: stagingURL,
                validateExecutableIdentity: true,
                requireSecureModes: true
            )
            let stagingExecutable = stagingURL.appendingPathComponent("esptool")
            _ = try versionChecker.version(
                executableURL: stagingExecutable,
                expectedVersion: descriptor.version
            )
            try replacePreparedDirectory(with: stagingURL)
        } catch let error as FlashingToolError {
            throw error
        } catch {
            throw FlashingToolError.fileFailure(error.localizedDescription)
        }

        let snapshot = inspect()
        guard snapshot.phase == .ready else {
            throw FlashingToolError.fileFailure(snapshot.detail)
        }
        return snapshot
    }

    func removeCachedArchive() throws -> FlashingToolSnapshot {
        try descriptor.validate()
        if fileManager.fileExists(atPath: preparedDirectoryURL.path) {
            try fileManager.removeItem(at: preparedDirectoryURL)
        }
        if fileManager.fileExists(atPath: archiveURL.path) {
            try fileManager.removeItem(at: archiveURL)
        }
        return FlashingToolSnapshot(
            descriptor: descriptor,
            phase: .missing,
            detail: "本地烧录工具归档和已准备目录均已移除；后台组件和设备固件均未改变。",
            archiveURL: nil,
            executableURL: nil
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

    private func validatePreparedDirectory(
        at directoryURL: URL,
        validateExecutableIdentity: Bool,
        requireSecureModes: Bool
    ) throws {
        let directoryValues = try directoryURL.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard directoryValues.isDirectory == true,
              directoryValues.isSymbolicLink != true else {
            throw FlashingToolError.payloadMismatch("准备目录必须是真实目录且不能是符号链接")
        }
        if requireSecureModes {
            let mode = try posixPermissions(at: directoryURL)
            guard mode == 0o700 else {
                throw FlashingToolError.payloadMismatch("准备目录权限必须是 0700")
            }
        }

        let entries = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: []
        )
        let actualNames = entries.map(\.lastPathComponent)
        let expectedNames = descriptor.payload.files.map(\.path)
        guard actualNames.count == expectedNames.count,
              Set(actualNames) == Set(expectedNames) else {
            throw FlashingToolError.payloadMismatch("准备目录包含缺失、额外或重复文件")
        }

        for file in descriptor.payload.files {
            let fileURL = directoryURL.appendingPathComponent(file.path)
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw FlashingToolError.payloadMismatch("\(file.path) 不是普通文件")
            }
            let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
            let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            guard size == file.size else {
                throw FlashingToolError.payloadMismatch("\(file.path) 大小不符")
            }
            let digest = try RuntimePayloadDigest.sha256(of: fileURL)
            guard digest == file.sha256 else {
                throw FlashingToolError.payloadMismatch("\(file.path) SHA-256 不符")
            }
            if requireSecureModes {
                let expectedMode: UInt16 = file.executable ? 0o700 : 0o600
                guard try posixPermissions(at: fileURL) == expectedMode else {
                    throw FlashingToolError.payloadMismatch("\(file.path) 私有权限不符")
                }
            }
            if validateExecutableIdentity, file.executable {
                guard let signingIdentifier = file.signingIdentifier else {
                    throw FlashingToolError.invalidDescriptor("缺少可执行文件签名标识")
                }
                try executableValidator.validate(
                    executableURL: fileURL,
                    teamIdentifier: descriptor.payload.signingTeamIdentifier,
                    signingIdentifier: signingIdentifier
                )
            }
        }
    }

    private func normalizePreparedPermissions(at directoryURL: URL) throws {
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directoryURL.path
        )
        for file in descriptor.payload.files {
            try fileManager.setAttributes(
                [.posixPermissions: file.executable ? 0o700 : 0o600],
                ofItemAtPath: directoryURL.appendingPathComponent(file.path).path
            )
        }
    }

    private func posixPermissions(at url: URL) throws -> UInt16 {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
    }

    private func replacePreparedDirectory(with stagingURL: URL) throws {
        let backupURL = cacheDirectory.appendingPathComponent(
            ".Prepared.noindex.backup-\(UUID().uuidString)",
            isDirectory: true
        )
        var movedExisting = false
        do {
            if fileManager.fileExists(atPath: preparedDirectoryURL.path) {
                try renameItem(at: preparedDirectoryURL, to: backupURL)
                movedExisting = true
            }
            try renameItem(at: stagingURL, to: preparedDirectoryURL)
            try validatePreparedDirectory(
                at: preparedDirectoryURL,
                validateExecutableIdentity: true,
                requireSecureModes: true
            )
            if movedExisting {
                try fileManager.removeItem(at: backupURL)
            }
        } catch {
            if fileManager.fileExists(atPath: preparedDirectoryURL.path) {
                try? fileManager.removeItem(at: preparedDirectoryURL)
            }
            if movedExisting, fileManager.fileExists(atPath: backupURL.path) {
                try? renameItem(at: backupURL, to: preparedDirectoryURL)
            }
            if let flashingError = error as? FlashingToolError {
                throw flashingError
            }
            throw FlashingToolError.fileFailure(error.localizedDescription)
        }
    }

    private func renameItem(at sourceURL: URL, to destinationURL: URL) throws {
        let result = sourceURL.path.withCString { sourcePath in
            destinationURL.path.withCString { destinationPath in
                Darwin.rename(sourcePath, destinationPath)
            }
        }
        guard result == 0 else {
            throw FlashingToolError.fileFailure(String(cString: strerror(errno)))
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
