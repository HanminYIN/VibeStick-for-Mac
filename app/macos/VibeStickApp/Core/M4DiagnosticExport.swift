import Foundation

// M4-5J turns the earlier diagnostic plan into an explicit, local-only export
// transaction. Preparing a preview reads only injected structured evidence and,
// when requested, fixed Bridge/HUD line sources. Export requires a matching
// preview confirmation and a caller-supplied destination that was selected by the
// user. This file does not upload, inspect devices, read Keychain, or control a
// runtime. Production filesystem code is compiled but is not invoked by App startup.

enum M4DiagnosticComponent: String, CaseIterable, Codable, Hashable, Sendable {
    case bridge
    case hud
    case paste
}

enum M4DiagnosticArchitecture: String, Codable, Equatable, Sendable {
    case arm64
    case x86_64
    case unknown
}

enum M4DiagnosticBridgeHealth: String, Codable, Equatable, Sendable {
    case healthy
    case unavailable
    case invalidResponse = "invalid-response"
}

struct M4DiagnosticComponentSummary: Codable, Equatable, Sendable {
    let component: M4DiagnosticComponent
    let healthy: Bool
    let signatureValid: Bool
}

struct M4DiagnosticLaunchAgentSummary: Codable, Equatable, Sendable {
    let component: M4DiagnosticComponent
    let loaded: Bool
    let running: Bool
    let ownedByCurrentUser: Bool
}

struct M4DiagnosticMigrationReceiptSummary: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let categories: [M4LegacyConfigurationCategory]
    let completedOperations: [M4MigrationTransactionOperation]
    let configurationCommitted: Bool
    let legacyFallbackRetained: Bool
    let legacyItemsDeleted: Bool
    let runtimeRestarted: Bool
}

struct M4DiagnosticRuntimeReceiptSummary: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let payloadVersion: String
    let installed: Bool
    let rolledBack: Bool
    let preservedPasteIdentity: Bool
}

struct M4DiagnosticStructuredSnapshot: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    let appVersion: String
    let appBuild: String
    let operatingSystemVersion: String
    let architecture: M4DiagnosticArchitecture
    let components: [M4DiagnosticComponentSummary]
    let launchAgents: [M4DiagnosticLaunchAgentSummary]
    let bridgeHealth: M4DiagnosticBridgeHealth
    let migrationReceipt: M4DiagnosticMigrationReceiptSummary?
    let runtimeReceipt: M4DiagnosticRuntimeReceiptSummary?

    func validated() throws -> Self {
        guard M4DiagnosticValidation.isSafeMetadata(appVersion),
              M4DiagnosticValidation.isSafeMetadata(appBuild),
              M4DiagnosticValidation.isSafeMetadata(operatingSystemVersion),
              M4DiagnosticValidation.isCompleteComponentSet(components.map(\.component)),
              M4DiagnosticValidation.isCompleteComponentSet(launchAgents.map(\.component)) else {
            throw M4DiagnosticExportError.invalidStructuredEvidence
        }
        if let migrationReceipt {
            guard migrationReceipt.schemaVersion == 1,
                  Set(migrationReceipt.categories).count == migrationReceipt.categories.count,
                  Set(migrationReceipt.completedOperations).count
                    == migrationReceipt.completedOperations.count else {
                throw M4DiagnosticExportError.invalidStructuredEvidence
            }
        }
        if let runtimeReceipt {
            guard runtimeReceipt.schemaVersion == 1,
                  M4DiagnosticValidation.isSafeMetadata(runtimeReceipt.payloadVersion),
                  !(runtimeReceipt.installed && runtimeReceipt.rolledBack) else {
                throw M4DiagnosticExportError.invalidStructuredEvidence
            }
        }
        return self
    }
}

enum M4DiagnosticLogKind: String, CaseIterable, Codable, Hashable, Sendable {
    case bridge
    case hud

    var relativePath: String {
        switch self {
        case .bridge: "logs/bridge-redacted.txt"
        case .hud: "logs/hud-redacted.txt"
        }
    }
}

protocol M4DiagnosticEvidenceReading: Sendable {
    func readStructuredSnapshot() async throws -> M4DiagnosticStructuredSnapshot
    func readLogLines(for kind: M4DiagnosticLogKind) async throws -> [String]
}

enum M4DiagnosticExportError: Error, Equatable, Sendable {
    case invalidStructuredEvidence
    case evidenceReadFailed
    case invalidLogLine
    case logLineTooLarge
    case unsafePlannedEntry
    case encodingFailed
    case unsafeDestination
    case unsafeExportIdentifier
    case pathOutsideDestination
    case symbolicLinkInDestination
    case destinationWasNotUserSelected
    case manifestConfirmationMismatch
    case bundleAlreadyExists
    case stagingFailed
    case validationFailed
    case promotionFailed
}

enum M4DiagnosticRedactor {
    static let maximumInputLineBytes = 8 * 1024
    static let maximumOutputLineCharacters = 512

    private static let rules: [(NSRegularExpression, String)] = {
        let definitions: [(String, String)] = [
            (#"(?i)(?<![A-Z0-9_])[\"']?(?:wifi[_-]?(?:ssid|pass(?:word)?)|ssid)[\"']?\s*[:=]\s*(?:\"[^\"]*\"|'[^']*'|[^\s,;]+)"#, "[REDACTED_WIFI]"),
            (#"(?i)\bauthorization\b\s*:\s*(?:bearer\s+)?[^\s,;]+"#, "[REDACTED_CREDENTIAL]"),
            (#"(?i)(?<![A-Z0-9_])[\"']?(?:authorization|api[_-]?key|token|secret|password|passwd)[\"']?\s*[:=]\s*(?:bearer\s+)?(?:\"[^\"]*\"|'[^']*'|[^\s,;]+)"#, "[REDACTED_CREDENTIAL]"),
            (#"(?i)(?<![A-Z0-9_])[\"']?(?:text|transcript|speech|utterance|recognized[_-]?text)[\"']?\s*[:=]\s*.*$"#, "[REDACTED_SPEECH]"),
            (#"(?i)(?<![A-Z0-9_])[\"']?(?:device|bridge|session|pairing)[_-]?(?:id|identifier)[\"']?\s*[:=]\s*(?:\"[^\"]*\"|'[^']*'|[^\s,;]+)"#, "[REDACTED_IDENTITY]"),
            (#"(?i)https?://[^\s\"'<>]+"#, "[REDACTED_ENDPOINT]"),
            (#"(?<=\")(?:(?:file://)?/|~/)[^\"\r\n]*(?=\")"#, "[REDACTED_PATH]"),
            (#"(?<=')(?:(?:file://)?/|~/)[^'\r\n]*(?=')"#, "[REDACTED_PATH]"),
            (#"(?<![A-Za-z0-9])~/(?:[^\r\n]*?)(?=(?:\s+(?:[A-Za-z_][A-Za-z0-9_.-]*\s*[:=]|\[REDACTED_[A-Z_]+\]|https?://|(?:\d{1,3}\.){3}\d{1,3}\b|(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}\b|(?i:[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,})\b))|$)"#, "[REDACTED_PATH]"),
            (#"(?<![A-Za-z0-9])(?:file://)?/(?:[^\r\n]*?)(?=(?:\s+(?:[A-Za-z_][A-Za-z0-9_.-]*\s*[:=]|\[REDACTED_[A-Z_]+\]|https?://|(?:\d{1,3}\.){3}\d{1,3}\b|(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}\b|(?i:[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,})\b))|$)"#, "[REDACTED_PATH]"),
            (#"\b(?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}\b"#, "[REDACTED_MAC]"),
            (#"\b(?:\d{1,3}\.){3}\d{1,3}\b"#, "[REDACTED_IP]"),
            (#"(?i)(?<![A-F0-9:])(?:[A-F0-9]{1,4}:){2,7}[A-F0-9]{1,4}(?![A-F0-9:])|::1"#, "[REDACTED_IP]"),
            (#"(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\b"#, "[REDACTED_IDENTITY]"),
            (#"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#, "[REDACTED_IDENTITY]"),
            (#"\b[A-Za-z0-9_-]{32,}\b"#, "[REDACTED_TOKEN]"),
        ]
        return definitions.map { pattern, replacement in
            (try! NSRegularExpression(pattern: pattern, options: []), replacement)
        }
    }()

    static func redact(line: String) throws -> String {
        guard !line.contains("\n"), !line.contains("\r") else {
            throw M4DiagnosticExportError.invalidLogLine
        }
        guard line.utf8.count <= maximumInputLineBytes else {
            throw M4DiagnosticExportError.logLineTooLarge
        }
        var result = line
        for (expression, replacement) in rules {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = expression.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: replacement
            )
        }
        if result.count > maximumOutputLineCharacters {
            result = String(result.prefix(maximumOutputLineCharacters)) + "[TRUNCATED]"
        }
        return result
    }
}

enum M4DiagnosticLogExcerptBuilder {
    static let maximumSourceLines = 200
    static let maximumOutputBytes = 32 * 1024
    static let truncationMarker = "[TRUNCATED]\n"

    static func makeExcerpt(from lines: [String]) throws -> Data {
        var output = Data()
        var wasTruncated = lines.count > maximumSourceLines
        for line in lines.prefix(maximumSourceLines) {
            let redacted = try M4DiagnosticRedactor.redact(line: line) + "\n"
            let data = Data(redacted.utf8)
            if output.count + data.count > maximumOutputBytes {
                wasTruncated = true
                break
            }
            output.append(data)
        }
        if wasTruncated {
            let marker = Data(truncationMarker.utf8)
            if output.count + marker.count <= maximumOutputBytes {
                output.append(marker)
            }
        }
        return output
    }
}

struct M4DiagnosticManifestEntry: Codable, Equatable, Sendable {
    let relativePath: String
    let source: M4DiagnosticSourceKind
    let byteCount: Int
}

struct M4DiagnosticManifestPreview: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let manifestRelativePath: String
    let entries: [M4DiagnosticManifestEntry]
    let includesRedactedLogExcerpts: Bool
    let includesRawLogs: Bool
    let uploadsAutomatically: Bool
}

struct M4PreparedDiagnosticFile: Equatable, Sendable {
    let relativePath: String
    let source: M4DiagnosticSourceKind
    let data: Data
}

struct M4PreparedDiagnosticExport: Equatable, Sendable {
    let manifest: M4DiagnosticManifestPreview
    let files: [M4PreparedDiagnosticFile]
}

struct M4DiagnosticExportAuthorization: Equatable, Sendable {
    let confirmedManifest: M4DiagnosticManifestPreview
    let destinationWasUserSelected: Bool
}

struct M4DiagnosticExportReceipt: Equatable, Sendable {
    static let schemaVersion = 1

    let bundleName: String
    let entryCount: Int
    let privatePermissionsValidated: Bool
    let uploaded: Bool
    let includesRawLogs: Bool
}

struct M4DiagnosticBundleBuilder: Sendable {
    private let evidenceReader: any M4DiagnosticEvidenceReading

    init(evidenceReader: any M4DiagnosticEvidenceReading) {
        self.evidenceReader = evidenceReader
    }

    func prepare(includeRedactedLogs: Bool) async throws -> M4PreparedDiagnosticExport {
        let snapshot: M4DiagnosticStructuredSnapshot
        do {
            snapshot = try await evidenceReader.readStructuredSnapshot().validated()
        } catch let error as M4DiagnosticExportError {
            throw error
        } catch {
            throw M4DiagnosticExportError.evidenceReadFailed
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let summary = M4DiagnosticSummaryDocument(
            schemaVersion: 1,
            appVersion: snapshot.appVersion,
            appBuild: snapshot.appBuild,
            components: snapshot.components.sorted { $0.component.rawValue < $1.component.rawValue },
            bridgeHealth: snapshot.bridgeHealth,
            migrationReceipt: snapshot.migrationReceipt,
            runtimeReceipt: snapshot.runtimeReceipt
        )
        let system = M4DiagnosticSystemDocument(
            schemaVersion: 1,
            operatingSystemVersion: snapshot.operatingSystemVersion,
            architecture: snapshot.architecture
        )
        let runtime = M4DiagnosticRuntimeDocument(
            schemaVersion: 1,
            launchAgents: snapshot.launchAgents.sorted {
                $0.component.rawValue < $1.component.rawValue
            }
        )

        var payloadFiles: [M4PreparedDiagnosticFile]
        do {
            payloadFiles = [
                M4PreparedDiagnosticFile(
                    relativePath: "summary-v1.json",
                    source: .componentHealth,
                    data: try encoder.encode(summary)
                ),
                M4PreparedDiagnosticFile(
                    relativePath: "system-v1.json",
                    source: .operatingSystemMetadata,
                    data: try encoder.encode(system)
                ),
                M4PreparedDiagnosticFile(
                    relativePath: "runtime-v1.json",
                    source: .launchAgentStatus,
                    data: try encoder.encode(runtime)
                ),
            ]
        } catch {
            throw M4DiagnosticExportError.encodingFailed
        }

        if includeRedactedLogs {
            for kind in M4DiagnosticLogKind.allCases {
                let lines: [String]
                do {
                    lines = try await evidenceReader.readLogLines(for: kind)
                } catch {
                    throw M4DiagnosticExportError.evidenceReadFailed
                }
                payloadFiles.append(
                    M4PreparedDiagnosticFile(
                        relativePath: kind.relativePath,
                        source: .redactedLogExcerpt,
                        data: try M4DiagnosticLogExcerptBuilder.makeExcerpt(from: lines)
                    )
                )
            }
        }

        payloadFiles.sort { $0.relativePath < $1.relativePath }
        let plan = M4DiagnosticPolicy.makePlan(includeRedactedLogs: includeRedactedLogs)
        try validate(plan: plan, payloadFiles: payloadFiles)
        let manifest = M4DiagnosticManifestPreview(
            schemaVersion: M4DiagnosticManifestPreview.schemaVersion,
            manifestRelativePath: "manifest-v1.json",
            entries: payloadFiles.map {
                M4DiagnosticManifestEntry(
                    relativePath: $0.relativePath,
                    source: $0.source,
                    byteCount: $0.data.count
                )
            },
            includesRedactedLogExcerpts: includeRedactedLogs,
            includesRawLogs: false,
            uploadsAutomatically: false
        )
        let manifestData: Data
        do {
            manifestData = try encoder.encode(manifest)
        } catch {
            throw M4DiagnosticExportError.encodingFailed
        }
        let manifestFile = M4PreparedDiagnosticFile(
            relativePath: manifest.manifestRelativePath,
            source: .appMetadata,
            data: manifestData
        )
        return M4PreparedDiagnosticExport(
            manifest: manifest,
            files: ([manifestFile] + payloadFiles).sorted { $0.relativePath < $1.relativePath }
        )
    }

    private func validate(
        plan: M4DiagnosticBundlePlan,
        payloadFiles: [M4PreparedDiagnosticFile]
    ) throws {
        let plannedPaths = plan.entries.map(\.relativePath)
        guard plan.requiresExplicitExportConfirmation,
              !plan.uploadsAutomatically,
              !plan.includesRawLogs,
              Set(plannedPaths).count == plannedPaths.count,
              plan.entries.allSatisfy({
                  M4DiagnosticPolicy.permits($0.source)
                    && M4DiagnosticPolicy.isSafeRelativePath($0.relativePath)
              }),
              payloadFiles.allSatisfy({
                  M4DiagnosticPolicy.permits($0.source)
                    && M4DiagnosticPolicy.isSafeRelativePath($0.relativePath)
                    && !M4DiagnosticPolicy.forbiddenSourceNames.contains(
                        URL(fileURLWithPath: $0.relativePath).lastPathComponent
                    )
              }) else {
            throw M4DiagnosticExportError.unsafePlannedEntry
        }
        let actualPaths = Set(payloadFiles.map(\.relativePath) + ["manifest-v1.json"])
        let plannedSources = Dictionary(
            uniqueKeysWithValues: plan.entries.map { ($0.relativePath, $0.source) }
        )
        let actualSources = Dictionary(
            uniqueKeysWithValues: payloadFiles.map { ($0.relativePath, $0.source) }
                + [("manifest-v1.json", M4DiagnosticSourceKind.appMetadata)]
        )
        guard actualPaths == Set(plannedPaths), actualSources == plannedSources else {
            throw M4DiagnosticExportError.unsafePlannedEntry
        }
    }
}

struct M4DiagnosticExportLocations: Equatable, Sendable {
    let destinationDirectory: URL
    let stagingDirectory: URL
    let finalDirectory: URL
    let bundleName: String

    static func make(
        destinationDirectory: URL,
        exportIdentifier: String
    ) throws -> Self {
        let root = destinationDirectory.standardizedFileURL
        guard root.isFileURL, root.path.hasPrefix("/"), root.path != "/" else {
            throw M4DiagnosticExportError.unsafeDestination
        }
        guard M4DiagnosticValidation.isSafeExportIdentifier(exportIdentifier) else {
            throw M4DiagnosticExportError.unsafeExportIdentifier
        }
        let bundleName = "VibeStick-Diagnostics-\(exportIdentifier).vibediagnostics"
        let staging = root.appendingPathComponent(".\(bundleName).staging.noindex", isDirectory: true)
        let final = root.appendingPathComponent(bundleName, isDirectory: true)
        guard M4DiagnosticValidation.isDescendant(staging, of: root),
              M4DiagnosticValidation.isDescendant(final, of: root) else {
            throw M4DiagnosticExportError.unsafeDestination
        }
        return Self(
            destinationDirectory: root,
            stagingDirectory: staging,
            finalDirectory: final,
            bundleName: bundleName
        )
    }
}

struct M4DiagnosticStoredItem: Equatable, Sendable {
    let relativePath: String
    let isDirectory: Bool
    let permissions: Int?
}

protocol M4DiagnosticFileSystemAccess: Sendable {
    func itemExists(at url: URL) async throws -> Bool
    func createPrivateDirectory(at url: URL) async throws
    func writePrivateFile(_ data: Data, to url: URL) async throws
    func readFile(at url: URL) async throws -> Data
    func permissions(at url: URL) async throws -> Int?
    func relativeItems(at root: URL) async throws -> [M4DiagnosticStoredItem]
    func atomicallyPromoteDirectory(from source: URL, to destination: URL) async throws
    func removeItem(at url: URL) async throws
}

struct M4FoundationDiagnosticFileSystem: M4DiagnosticFileSystemAccess, Sendable {
    private let authorizedRoot: URL

    init(authorizedRoot: URL) throws {
        let root = authorizedRoot.standardizedFileURL
        guard root.isFileURL, root.path.hasPrefix("/"), root.path != "/" else {
            throw M4DiagnosticExportError.unsafeDestination
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw M4DiagnosticExportError.unsafeDestination
        }
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: root.path)
        } catch {
            throw M4DiagnosticExportError.unsafeDestination
        }
        guard attributes[.type] as? FileAttributeType != .typeSymbolicLink else {
            throw M4DiagnosticExportError.symbolicLinkInDestination
        }
        self.authorizedRoot = root
    }

    func itemExists(at url: URL) throws -> Bool {
        FileManager.default.fileExists(atPath: try validated(url).path)
    }

    func createPrivateDirectory(at url: URL) throws {
        let candidate = try validated(url)
        try FileManager.default.createDirectory(
            at: candidate,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        _ = try validated(candidate)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: candidate.path
        )
    }

    func writePrivateFile(_ data: Data, to url: URL) throws {
        let candidate = try validated(url)
        _ = try validated(candidate.deletingLastPathComponent())
        try data.write(to: candidate, options: .atomic)
        _ = try validated(candidate)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: candidate.path
        )
    }

    func readFile(at url: URL) throws -> Data {
        try Data(contentsOf: validated(url), options: [.mappedIfSafe])
    }

    func permissions(at url: URL) throws -> Int? {
        let candidate = try validated(url)
        let attributes = try FileManager.default.attributesOfItem(atPath: candidate.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue
    }

    func relativeItems(at root: URL) throws -> [M4DiagnosticStoredItem] {
        let validatedRoot = try validated(root)
        var items: [M4DiagnosticStoredItem] = []
        try appendItems(in: validatedRoot, relativePrefix: "", to: &items)
        return items.sorted { $0.relativePath < $1.relativePath }
    }

    func atomicallyPromoteDirectory(from source: URL, to destination: URL) throws {
        let validatedSource = try validated(source)
        let validatedDestination = try validated(destination)
        guard FileManager.default.fileExists(atPath: validatedSource.path),
              !FileManager.default.fileExists(atPath: validatedDestination.path) else {
            throw M4DiagnosticExportError.bundleAlreadyExists
        }
        try FileManager.default.moveItem(at: validatedSource, to: validatedDestination)
    }

    func removeItem(at url: URL) throws {
        let candidate = try validated(url)
        if FileManager.default.fileExists(atPath: candidate.path) {
            try FileManager.default.removeItem(at: candidate)
        }
    }

    private func appendItems(
        in directory: URL,
        relativePrefix: String,
        to items: inout [M4DiagnosticStoredItem]
    ) throws {
        let manager = FileManager.default
        for child in try manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) {
            let candidate = try validated(child)
            let values = try candidate.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw M4DiagnosticExportError.symbolicLinkInDestination
            }
            let relativePath = relativePrefix.isEmpty
                ? candidate.lastPathComponent
                : relativePrefix + "/" + candidate.lastPathComponent
            let attributes = try manager.attributesOfItem(atPath: candidate.path)
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
            let isDirectory = values.isDirectory == true
            items.append(
                M4DiagnosticStoredItem(
                    relativePath: relativePath,
                    isDirectory: isDirectory,
                    permissions: permissions
                )
            )
            if isDirectory {
                try appendItems(in: candidate, relativePrefix: relativePath, to: &items)
            }
        }
    }

    private func validated(_ url: URL) throws -> URL {
        let candidate = url.standardizedFileURL
        guard candidate == authorizedRoot
                || M4DiagnosticValidation.isDescendant(candidate, of: authorizedRoot) else {
            throw M4DiagnosticExportError.pathOutsideDestination
        }
        let resolvedRoot = authorizedRoot.resolvingSymlinksInPath().standardizedFileURL
        let resolvedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedCandidate == resolvedRoot
                || M4DiagnosticValidation.isDescendant(resolvedCandidate, of: resolvedRoot) else {
            throw M4DiagnosticExportError.pathOutsideDestination
        }
        try rejectExistingSymbolicLinkComponents(to: candidate)
        return candidate
    }

    private func rejectExistingSymbolicLinkComponents(to candidate: URL) throws {
        let manager = FileManager.default
        let rootPath = authorizedRoot.path
        let suffix = String(candidate.path.dropFirst(rootPath.count))
        var current = authorizedRoot
        var components = suffix.split(separator: "/").map(String.init)
        components.insert("", at: 0)
        for component in components {
            if !component.isEmpty { current.appendPathComponent(component) }
            guard manager.fileExists(atPath: current.path) else { continue }
            let attributes = try manager.attributesOfItem(atPath: current.path)
            if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                throw M4DiagnosticExportError.symbolicLinkInDestination
            }
        }
    }
}

actor M4DiagnosticExportTransaction {
    nonisolated let locations: M4DiagnosticExportLocations

    private let fileSystem: any M4DiagnosticFileSystemAccess

    init(
        locations: M4DiagnosticExportLocations,
        fileSystem: any M4DiagnosticFileSystemAccess
    ) {
        self.locations = locations
        self.fileSystem = fileSystem
    }

    static func live(
        destinationDirectory: URL,
        exportIdentifier: String = UUID().uuidString.lowercased()
    ) throws -> M4DiagnosticExportTransaction {
        let locations = try M4DiagnosticExportLocations.make(
            destinationDirectory: destinationDirectory,
            exportIdentifier: exportIdentifier
        )
        return M4DiagnosticExportTransaction(
            locations: locations,
            fileSystem: try M4FoundationDiagnosticFileSystem(
                authorizedRoot: locations.destinationDirectory
            )
        )
    }

    func export(
        _ prepared: M4PreparedDiagnosticExport,
        authorization: M4DiagnosticExportAuthorization
    ) async throws -> M4DiagnosticExportReceipt {
        guard authorization.destinationWasUserSelected else {
            throw M4DiagnosticExportError.destinationWasNotUserSelected
        }
        guard authorization.confirmedManifest == prepared.manifest else {
            throw M4DiagnosticExportError.manifestConfirmationMismatch
        }
        let bundleAlreadyExists: Bool
        do {
            let stagingExists = try await fileSystem.itemExists(at: locations.stagingDirectory)
            let finalExists = try await fileSystem.itemExists(at: locations.finalDirectory)
            bundleAlreadyExists = stagingExists || finalExists
        } catch {
            throw M4DiagnosticExportError.stagingFailed
        }
        guard !bundleAlreadyExists else {
            throw M4DiagnosticExportError.bundleAlreadyExists
        }

        do {
            try await fileSystem.createPrivateDirectory(at: locations.stagingDirectory)
            for directory in requiredDirectories(for: prepared.files) {
                try await fileSystem.createPrivateDirectory(
                    at: locations.stagingDirectory.appendingPathComponent(
                        directory,
                        isDirectory: true
                    )
                )
            }
            for file in prepared.files {
                try await fileSystem.writePrivateFile(
                    file.data,
                    to: locations.stagingDirectory.appendingPathComponent(file.relativePath)
                )
            }
        } catch let error as M4DiagnosticExportError {
            try? await fileSystem.removeItem(at: locations.stagingDirectory)
            throw error
        } catch {
            try? await fileSystem.removeItem(at: locations.stagingDirectory)
            throw M4DiagnosticExportError.stagingFailed
        }

        do {
            try await validateStaging(prepared)
        } catch {
            try? await fileSystem.removeItem(at: locations.stagingDirectory)
            throw M4DiagnosticExportError.validationFailed
        }

        do {
            try await fileSystem.atomicallyPromoteDirectory(
                from: locations.stagingDirectory,
                to: locations.finalDirectory
            )
        } catch {
            try? await fileSystem.removeItem(at: locations.stagingDirectory)
            throw M4DiagnosticExportError.promotionFailed
        }

        return M4DiagnosticExportReceipt(
            bundleName: locations.bundleName,
            entryCount: prepared.files.count,
            privatePermissionsValidated: true,
            uploaded: false,
            includesRawLogs: false
        )
    }

    private func validateStaging(_ prepared: M4PreparedDiagnosticExport) async throws {
        let items = try await fileSystem.relativeItems(at: locations.stagingDirectory)
        let expectedDirectories = Set(requiredDirectories(for: prepared.files))
        let expectedFiles = Set(prepared.files.map(\.relativePath))
        let actualDirectories = Set(items.filter(\.isDirectory).map(\.relativePath))
        let actualFiles = Set(items.filter { !$0.isDirectory }.map(\.relativePath))
        guard try await fileSystem.permissions(at: locations.stagingDirectory) == 0o700,
              expectedDirectories == actualDirectories,
              expectedFiles == actualFiles,
              items.allSatisfy({ $0.permissions == ($0.isDirectory ? 0o700 : 0o600) }) else {
            throw M4DiagnosticExportError.validationFailed
        }
        for file in prepared.files {
            let stored = try await fileSystem.readFile(
                at: locations.stagingDirectory.appendingPathComponent(file.relativePath)
            )
            guard stored == file.data else {
                throw M4DiagnosticExportError.validationFailed
            }
        }
        guard let manifestFile = prepared.files.first(where: {
            $0.relativePath == prepared.manifest.manifestRelativePath
        }),
              let decoded = try? JSONDecoder().decode(
                M4DiagnosticManifestPreview.self,
                from: manifestFile.data
              ),
              decoded == prepared.manifest else {
            throw M4DiagnosticExportError.validationFailed
        }
    }

    private func requiredDirectories(
        for files: [M4PreparedDiagnosticFile]
    ) -> [String] {
        var directories: Set<String> = []
        for file in files {
            let components = file.relativePath.split(separator: "/").map(String.init)
            guard components.count > 1 else { continue }
            var current: [String] = []
            for component in components.dropLast() {
                current.append(component)
                directories.insert(current.joined(separator: "/"))
            }
        }
        return directories.sorted {
            let leftDepth = $0.split(separator: "/").count
            let rightDepth = $1.split(separator: "/").count
            return leftDepth == rightDepth ? $0 < $1 : leftDepth < rightDepth
        }
    }
}

private enum M4DiagnosticValidation {
    static func isSafeMetadata(_ value: String) -> Bool {
        guard (1...80).contains(value.count),
              !value.contains("/"),
              !value.contains("\\"),
              !value.contains(":"),
              !value.contains("="),
              !value.contains("@"),
              !value.contains("\n"),
              !value.contains("\r") else {
            return false
        }
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 ._+()-"
        )
        return value.unicodeScalars.allSatisfy(allowed.contains)
    }

    static func isCompleteComponentSet(_ values: [M4DiagnosticComponent]) -> Bool {
        values.count == M4DiagnosticComponent.allCases.count
            && Set(values) == Set(M4DiagnosticComponent.allCases)
    }

    static func isSafeExportIdentifier(_ value: String) -> Bool {
        guard (1...80).contains(value.count) else { return false }
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
        )
        return value.unicodeScalars.allSatisfy(allowed.contains)
    }

    static func isDescendant(_ candidate: URL, of root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let candidatePath = candidate.standardizedFileURL.path
        return candidatePath.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
    }
}

private struct M4DiagnosticSummaryDocument: Codable {
    let schemaVersion: Int
    let appVersion: String
    let appBuild: String
    let components: [M4DiagnosticComponentSummary]
    let bridgeHealth: M4DiagnosticBridgeHealth
    let migrationReceipt: M4DiagnosticMigrationReceiptSummary?
    let runtimeReceipt: M4DiagnosticRuntimeReceiptSummary?
}

private struct M4DiagnosticSystemDocument: Codable {
    let schemaVersion: Int
    let operatingSystemVersion: String
    let architecture: M4DiagnosticArchitecture
}

private struct M4DiagnosticRuntimeDocument: Codable {
    let schemaVersion: Int
    let launchAgents: [M4DiagnosticLaunchAgentSummary]
}
