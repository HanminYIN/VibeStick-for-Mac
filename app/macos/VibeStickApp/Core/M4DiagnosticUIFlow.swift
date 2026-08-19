import AppKit
import Combine
import Darwin
import Foundation
import Security

// M4-5K connects the local-only M4-5J transaction to an explicit UI flow.
// Constructing the production objects is inert. Structured evidence is copied
// from an already-redacted in-memory snapshot, and fixed Bridge/HUD log files
// are opened only after the user requests a preview that includes excerpts.

protocol M4DiagnosticStructuredSnapshotReading: Sendable {
    func readStructuredSnapshot() async throws -> M4DiagnosticStructuredSnapshot
}

actor M4DiagnosticSnapshotStore: M4DiagnosticStructuredSnapshotReading {
    private var snapshot: M4DiagnosticStructuredSnapshot

    init(snapshot: M4DiagnosticStructuredSnapshot) {
        self.snapshot = snapshot
    }

    func replace(with snapshot: M4DiagnosticStructuredSnapshot) {
        self.snapshot = snapshot
    }

    func readStructuredSnapshot() -> M4DiagnosticStructuredSnapshot {
        snapshot
    }
}

struct M4DiagnosticTailData: Equatable, Sendable {
    let data: Data
    let startedAfterBeginning: Bool
}

protocol M4DiagnosticBoundedFileReading: Sendable {
    func readTail(at url: URL, maximumBytes: Int) async throws -> M4DiagnosticTailData?
}

enum M4DiagnosticEvidenceAdapterError: Error, Equatable, Sendable {
    case unsafeRoot
    case unsafeSource
    case invalidFileType
    case readFailed
    case sourceChanged
}

struct M4FoundationDiagnosticBoundedFileReader: M4DiagnosticBoundedFileReading, Sendable {
    static let maximumPermittedReadBytes = 64 * 1024

    private let authorizedRoot: URL

    init(authorizedRoot: URL) {
        self.authorizedRoot = authorizedRoot.standardizedFileURL
    }

    func readTail(at url: URL, maximumBytes: Int) throws -> M4DiagnosticTailData? {
        let candidate = url.standardizedFileURL
        guard authorizedRoot.isFileURL,
              authorizedRoot.path.hasPrefix("/"),
              authorizedRoot.path != "/",
              candidate.deletingLastPathComponent().standardizedFileURL == authorizedRoot,
              (1...Self.maximumPermittedReadBytes).contains(maximumBytes) else {
            throw M4DiagnosticEvidenceAdapterError.unsafeSource
        }

        var rootStatus = stat()
        if Darwin.lstat(authorizedRoot.path, &rootStatus) == 0,
           (rootStatus.st_mode & S_IFMT) == S_IFLNK {
            throw M4DiagnosticEvidenceAdapterError.unsafeRoot
        }
        let resolvedRoot = authorizedRoot.resolvingSymlinksInPath().standardizedFileURL
        let resolvedParent = candidate.deletingLastPathComponent()
            .resolvingSymlinksInPath().standardizedFileURL
        guard resolvedParent == resolvedRoot else {
            throw M4DiagnosticEvidenceAdapterError.unsafeSource
        }

        let descriptor = Darwin.open(candidate.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            if errno == ELOOP { throw M4DiagnosticEvidenceAdapterError.invalidFileType }
            throw M4DiagnosticEvidenceAdapterError.readFailed
        }
        defer { Darwin.close(descriptor) }

        var before = stat()
        guard Darwin.fstat(descriptor, &before) == 0,
              (before.st_mode & S_IFMT) == S_IFREG,
              before.st_size >= 0 else {
            throw M4DiagnosticEvidenceAdapterError.invalidFileType
        }

        let fileSize = Int(before.st_size)
        let byteCount = min(fileSize, maximumBytes)
        let startOffset = fileSize - byteCount
        guard Darwin.lseek(descriptor, off_t(startOffset), SEEK_SET) == off_t(startOffset) else {
            throw M4DiagnosticEvidenceAdapterError.readFailed
        }

        var data = Data(count: byteCount)
        let bytesRead = data.withUnsafeMutableBytes { buffer -> Int in
            guard byteCount > 0, let base = buffer.baseAddress else { return 0 }
            var total = 0
            while total < byteCount {
                let result = Darwin.read(
                    descriptor,
                    base.advanced(by: total),
                    byteCount - total
                )
                if result < 0 {
                    if errno == EINTR { continue }
                    return -1
                }
                if result == 0 { break }
                total += result
            }
            return total
        }
        guard bytesRead >= 0 else {
            throw M4DiagnosticEvidenceAdapterError.readFailed
        }
        data.count = bytesRead

        var after = stat()
        guard Darwin.fstat(descriptor, &after) == 0,
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else {
            throw M4DiagnosticEvidenceAdapterError.sourceChanged
        }
        return M4DiagnosticTailData(
            data: data,
            startedAfterBeginning: startOffset > 0
        )
    }
}

protocol M4DiagnosticLogSourceReading: Sendable {
    func readLogLines(for kind: M4DiagnosticLogKind) async throws -> [String]
}

protocol M4DiagnosticComponentSignatureReading: Sendable {
    func readSignatureValidity() async -> [M4DiagnosticComponent: Bool]
}

struct M4ProductionDiagnosticComponentSignatureReader:
    M4DiagnosticComponentSignatureReading,
    Sendable
{
    private let applications: [M4DiagnosticComponent: URL]

    init(bridge: URL, hud: URL, paste: URL) {
        applications = [
            .bridge: bridge.standardizedFileURL,
            .hud: hud.standardizedFileURL,
            .paste: paste.standardizedFileURL,
        ]
    }

    func readSignatureValidity() -> [M4DiagnosticComponent: Bool] {
        Dictionary(uniqueKeysWithValues: M4DiagnosticComponent.allCases.map { component in
            (component, applications[component].map(signatureIsValid) ?? false)
        })
    }

    private func signatureIsValid(at application: URL) -> Bool {
        var staticCode: SecStaticCode?
        var status = SecStaticCodeCreateWithPath(
            application as CFURL,
            SecCSFlags(rawValue: 0),
            &staticCode
        )
        guard status == errSecSuccess, let staticCode else { return false }
        status = SecStaticCodeCheckValidity(
            staticCode,
            SecCSFlags(rawValue: kSecCSStrictValidate),
            nil
        )
        return status == errSecSuccess
    }
}

struct M4ProductionDiagnosticLogSourceReader: M4DiagnosticLogSourceReading, Sendable {
    static let maximumBytesPerFile = 16 * 1024
    static let maximumLinesPerFile = 100
    static let maximumCombinedLines = 200

    private let supportDirectory: URL
    private let fileReader: any M4DiagnosticBoundedFileReading

    init(
        supportDirectory: URL,
        fileReader: (any M4DiagnosticBoundedFileReading)? = nil
    ) {
        let root = supportDirectory.standardizedFileURL
        self.supportDirectory = root
        self.fileReader = fileReader
            ?? M4FoundationDiagnosticBoundedFileReader(authorizedRoot: root)
    }

    func readLogLines(for kind: M4DiagnosticLogKind) async throws -> [String] {
        let names: [String]
        switch kind {
        case .bridge:
            names = ["bridge.log", "bridge.err.log"]
        case .hud:
            names = ["hud.log", "hud.err.log"]
        }

        var combined: [String] = []
        for name in names {
            let url = supportDirectory.appendingPathComponent(name, isDirectory: false)
            guard let tail = try await fileReader.readTail(
                at: url,
                maximumBytes: Self.maximumBytesPerFile
            ) else { continue }
            var text = String(decoding: tail.data, as: UTF8.self)
            if tail.startedAfterBeginning,
               let newline = text.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
                text = String(text[text.index(after: newline)...])
            } else if tail.startedAfterBeginning {
                text = ""
            }
            let lines = text.split(
                whereSeparator: { $0 == "\n" || $0 == "\r" }
            ).suffix(Self.maximumLinesPerFile).map(String.init)
            combined.append(contentsOf: lines)
        }
        return Array(combined.suffix(Self.maximumCombinedLines))
    }
}

struct M4ProductionDiagnosticEvidenceReader: M4DiagnosticEvidenceReading, Sendable {
    private let snapshotReader: any M4DiagnosticStructuredSnapshotReading
    private let logReader: any M4DiagnosticLogSourceReading
    private let signatureReader: (any M4DiagnosticComponentSignatureReading)?

    init(
        snapshotReader: any M4DiagnosticStructuredSnapshotReading,
        logReader: any M4DiagnosticLogSourceReading,
        signatureReader: (any M4DiagnosticComponentSignatureReading)? = nil
    ) {
        self.snapshotReader = snapshotReader
        self.logReader = logReader
        self.signatureReader = signatureReader
    }

    func readStructuredSnapshot() async throws -> M4DiagnosticStructuredSnapshot {
        let snapshot = try await snapshotReader.readStructuredSnapshot()
        guard let signatureReader else { return snapshot }
        let signatures = await signatureReader.readSignatureValidity()
        return M4DiagnosticStructuredSnapshot(
            appVersion: snapshot.appVersion,
            appBuild: snapshot.appBuild,
            operatingSystemVersion: snapshot.operatingSystemVersion,
            architecture: snapshot.architecture,
            components: snapshot.components.map {
                M4DiagnosticComponentSummary(
                    component: $0.component,
                    healthy: $0.healthy,
                    signatureValid: signatures[$0.component] ?? false
                )
            },
            launchAgents: snapshot.launchAgents,
            bridgeHealth: snapshot.bridgeHealth,
            migrationReceipt: snapshot.migrationReceipt,
            runtimeReceipt: snapshot.runtimeReceipt
        )
    }

    func readLogLines(for kind: M4DiagnosticLogKind) async throws -> [String] {
        try await logReader.readLogLines(for: kind)
    }
}

enum M4DiagnosticAppSnapshotFactory {
    static func make(
        appVersion: String,
        appBuild: String,
        bridge: BridgeSnapshot,
        runtime: RuntimeSnapshot,
        migrationReceipt: M4DiagnosticMigrationReceiptSummary?,
        runtimeReceipt: M4DiagnosticRuntimeReceiptSummary?
    ) -> M4DiagnosticStructuredSnapshot {
        let components = [runtime.bridge, runtime.hud, runtime.paste]
        return M4DiagnosticStructuredSnapshot(
            appVersion: appVersion,
            appBuild: appBuild,
            operatingSystemVersion: operatingSystemVersion,
            architecture: architecture,
            components: components.map { component in
                M4DiagnosticComponentSummary(
                    component: diagnosticComponent(component.kind),
                    healthy: component.phase == .healthy,
                    signatureValid: signatureWasAccepted(component)
                )
            },
            launchAgents: components.map { component in
                let isLaunchAgent = component.kind != .paste
                return M4DiagnosticLaunchAgentSummary(
                    component: diagnosticComponent(component.kind),
                    loaded: isLaunchAgent && component.isInstalled,
                    running: isLaunchAgent && isRunning(component.phase),
                    ownedByCurrentUser: component.ownership != .externalProcess
                        && component.ownership != .conflictingProcess
                )
            },
            bridgeHealth: bridge.isHealthy
                ? .healthy
                : (bridge.healthEndpointResponded ? .invalidResponse : .unavailable),
            migrationReceipt: migrationReceipt,
            runtimeReceipt: runtimeReceipt
        )
    }

    static func migrationReceipt(
        from receipt: M4LegacyMigrationReceiptSummary
    ) -> M4DiagnosticMigrationReceiptSummary {
        M4DiagnosticMigrationReceiptSummary(
            schemaVersion: M4LegacyMigrationReceiptSummary.schemaVersion,
            categories: receipt.categories,
            completedOperations: receipt.completedOperations,
            configurationCommitted: receipt.configurationCommitted,
            legacyFallbackRetained: receipt.legacyFallbackRetained,
            legacyItemsDeleted: receipt.legacyItemsDeleted,
            runtimeRestarted: receipt.runtimeRestarted
        )
    }

    static func runtimeReceipt(
        from receipt: RuntimeInstallReceipt
    ) -> M4DiagnosticRuntimeReceiptSummary {
        M4DiagnosticRuntimeReceiptSummary(
            schemaVersion: M4DiagnosticRuntimeReceiptSummary.schemaVersion,
            payloadVersion: receipt.payloadVersion,
            installed: true,
            rolledBack: false,
            preservedPasteIdentity: receipt.preservedPasteIdentity
        )
    }

    private static var operatingSystemVersion: String {
        let value = ProcessInfo.processInfo.operatingSystemVersion
        return "\(value.majorVersion).\(value.minorVersion).\(value.patchVersion)"
    }

    private static var architecture: M4DiagnosticArchitecture {
        #if arch(arm64)
        .arm64
        #elseif arch(x86_64)
        .x86_64
        #else
        .unknown
        #endif
    }

    private static func diagnosticComponent(_ kind: ComponentKind) -> M4DiagnosticComponent {
        switch kind {
        case .bridge: .bridge
        case .hud: .hud
        case .paste: .paste
        }
    }

    private static func signatureWasAccepted(_ component: ComponentHealth) -> Bool {
        component.isInstalled
            && component.phase != .versionMismatch
            && component.ownership != .externalProcess
            && component.ownership != .conflictingProcess
    }

    private static func isRunning(_ phase: ServicePhase) -> Bool {
        switch phase {
        case .healthy, .runningNotReady, .permissionMissing, .portConflict:
            true
        case .notInstalled, .stopped, .starting, .versionMismatch, .needsRepair, .unknown:
            false
        }
    }
}

protocol M4DiagnosticUIOperating: Sendable {
    func prepare(includeRedactedLogs: Bool) async throws -> M4PreparedDiagnosticExport
    func export(
        prepared: M4PreparedDiagnosticExport,
        destinationDirectory: URL
    ) async throws -> M4DiagnosticExportReceipt
}

protocol M4DiagnosticUIOperationBuilding: Sendable {
    func makeOperation() throws -> any M4DiagnosticUIOperating
}

struct M4LiveDiagnosticUIOperation: M4DiagnosticUIOperating, Sendable {
    private let builder: M4DiagnosticBundleBuilder

    init(evidenceReader: any M4DiagnosticEvidenceReading) {
        builder = M4DiagnosticBundleBuilder(evidenceReader: evidenceReader)
    }

    func prepare(includeRedactedLogs: Bool) async throws -> M4PreparedDiagnosticExport {
        try await builder.prepare(includeRedactedLogs: includeRedactedLogs)
    }

    func export(
        prepared: M4PreparedDiagnosticExport,
        destinationDirectory: URL
    ) async throws -> M4DiagnosticExportReceipt {
        let transaction = try M4DiagnosticExportTransaction.live(
            destinationDirectory: destinationDirectory
        )
        return try await transaction.export(
            prepared,
            authorization: M4DiagnosticExportAuthorization(
                confirmedManifest: prepared.manifest,
                destinationWasUserSelected: true
            )
        )
    }
}

struct M4ProductionDiagnosticUIOperationBuilder: M4DiagnosticUIOperationBuilding, Sendable {
    private let evidenceReader: any M4DiagnosticEvidenceReading

    init(
        snapshotReader: any M4DiagnosticStructuredSnapshotReading,
        logReader: any M4DiagnosticLogSourceReading,
        signatureReader: (any M4DiagnosticComponentSignatureReading)? = nil
    ) {
        evidenceReader = M4ProductionDiagnosticEvidenceReader(
            snapshotReader: snapshotReader,
            logReader: logReader,
            signatureReader: signatureReader
        )
    }

    func makeOperation() -> any M4DiagnosticUIOperating {
        M4LiveDiagnosticUIOperation(evidenceReader: evidenceReader)
    }
}

@MainActor
protocol M4DiagnosticDestinationSelecting: AnyObject {
    func selectDestination() async -> URL?
}

@MainActor
final class M4SystemDiagnosticDestinationSelector: M4DiagnosticDestinationSelecting {
    func selectDestination() async -> URL? {
        let panel = NSOpenPanel()
        panel.title = "选择诊断包的本地保存文件夹"
        panel.message = "只会在所选文件夹创建经过预览和确认的脱敏诊断包。"
        panel.prompt = "选择此文件夹"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.resolvesAliases = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}

struct M4DiagnosticUIPreviewEntry: Equatable, Sendable {
    let relativePath: String
    let source: M4DiagnosticSourceKind
    let byteCount: Int
}

struct M4DiagnosticUIPreview: Equatable, Sendable {
    let schemaVersion: Int
    let entries: [M4DiagnosticUIPreviewEntry]
    let includesRedactedLogExcerpts: Bool
    let includesRawLogs: Bool
    let uploadsAutomatically: Bool

    init(manifest: M4DiagnosticManifestPreview) {
        schemaVersion = manifest.schemaVersion
        entries = manifest.entries.map {
            M4DiagnosticUIPreviewEntry(
                relativePath: $0.relativePath,
                source: $0.source,
                byteCount: $0.byteCount
            )
        }
        includesRedactedLogExcerpts = manifest.includesRedactedLogExcerpts
        includesRawLogs = manifest.includesRawLogs
        uploadsAutomatically = manifest.uploadsAutomatically
    }

    var totalByteCount: Int {
        entries.reduce(0) { $0 + $1.byteCount }
    }
}

struct M4DiagnosticUIReview: Equatable, Sendable {
    let preview: M4DiagnosticUIPreview
    let destinationSelected: Bool
}

struct M4DiagnosticUIFinalConfirmationSummary: Equatable, Sendable {
    let entryCount: Int
    let totalByteCount: Int
    let includesRedactedLogExcerpts: Bool

    var redactedMessage: String {
        [
            "固定 schema：1",
            "导出条目：\(entryCount) 项",
            "预计内容大小：\(totalByteCount) 字节",
            "脱敏日志摘录：\(includesRedactedLogExcerpts ? "包含" : "不包含")",
            "原始日志：不包含",
            "自动上传：不会",
            "将在已选择的本地文件夹创建 0700/0600 私有诊断包；这里不显示完整保存路径。",
        ].joined(separator: "\n")
    }
}

enum M4DiagnosticUIFailure: String, Equatable, Sendable {
    case previewFailed
    case exportFailed
}

enum M4DiagnosticUIState: Equatable, Sendable {
    case idle
    case preparing
    case reviewing(M4DiagnosticUIReview)
    case awaitingFinalConfirmation(M4DiagnosticUIReview)
    case exporting(M4DiagnosticUIPreview)
    case completed(M4DiagnosticExportReceipt)
    case failed(M4DiagnosticUIFailure)
}

@MainActor
final class M4DiagnosticUIFlow: ObservableObject {
    @Published private(set) var state: M4DiagnosticUIState = .idle
    @Published private(set) var includesRedactedLogs = false

    private let builder: any M4DiagnosticUIOperationBuilding
    private let destinationSelector: any M4DiagnosticDestinationSelecting
    private var operation: (any M4DiagnosticUIOperating)?
    private var prepared: M4PreparedDiagnosticExport?
    private var destinationDirectory: URL?

    init(
        builder: any M4DiagnosticUIOperationBuilding,
        destinationSelector: any M4DiagnosticDestinationSelecting
    ) {
        self.builder = builder
        self.destinationSelector = destinationSelector
    }

    var isAwaitingFinalConfirmation: Bool {
        if case .awaitingFinalConfirmation = state { return true }
        return false
    }

    var finalConfirmationSummary: M4DiagnosticUIFinalConfirmationSummary? {
        guard case let .awaitingFinalConfirmation(review) = state else { return nil }
        return M4DiagnosticUIFinalConfirmationSummary(
            entryCount: review.preview.entries.count,
            totalByteCount: review.preview.totalByteCount,
            includesRedactedLogExcerpts: review.preview.includesRedactedLogExcerpts
        )
    }

    func setIncludesRedactedLogs(_ included: Bool) {
        guard case .idle = state else { return }
        includesRedactedLogs = included
    }

    func preparePreview() async {
        guard case .idle = state else { return }
        operation = nil
        prepared = nil
        destinationDirectory = nil
        state = .preparing
        do {
            let created = try builder.makeOperation()
            let result = try await created.prepare(includeRedactedLogs: includesRedactedLogs)
            operation = created
            prepared = result
            state = .reviewing(
                M4DiagnosticUIReview(
                    preview: M4DiagnosticUIPreview(manifest: result.manifest),
                    destinationSelected: false
                )
            )
        } catch {
            operation = nil
            prepared = nil
            state = .failed(.previewFailed)
        }
    }

    func selectDestination() async {
        guard case let .reviewing(review) = state else { return }
        guard let selected = await destinationSelector.selectDestination() else { return }
        destinationDirectory = selected.standardizedFileURL
        state = .reviewing(
            M4DiagnosticUIReview(
                preview: review.preview,
                destinationSelected: true
            )
        )
    }

    @discardableResult
    func requestFinalConfirmation() -> Bool {
        guard case let .reviewing(review) = state,
              review.destinationSelected,
              destinationDirectory != nil,
              prepared != nil,
              operation != nil else { return false }
        state = .awaitingFinalConfirmation(review)
        return true
    }

    func cancelFinalConfirmation() {
        guard case let .awaitingFinalConfirmation(review) = state else { return }
        state = .reviewing(review)
    }

    func confirmExport() async {
        guard case let .awaitingFinalConfirmation(review) = state,
              review.destinationSelected,
              let destinationDirectory,
              let prepared,
              let operation else { return }
        state = .exporting(review.preview)
        do {
            let receipt = try await operation.export(
                prepared: prepared,
                destinationDirectory: destinationDirectory
            )
            self.operation = nil
            self.prepared = nil
            self.destinationDirectory = nil
            state = .completed(receipt)
        } catch {
            self.operation = nil
            self.prepared = nil
            self.destinationDirectory = nil
            state = .failed(.exportFailed)
        }
    }

    func reset() {
        guard !isBusy else { return }
        operation = nil
        prepared = nil
        destinationDirectory = nil
        includesRedactedLogs = false
        state = .idle
    }

    private var isBusy: Bool {
        switch state {
        case .preparing, .exporting:
            true
        case .idle, .reviewing, .awaitingFinalConfirmation, .completed, .failed:
            false
        }
    }
}
