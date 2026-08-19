import Foundation
import Testing

struct M4DiagnosticExportTests {
    @Test
    func redactorReplacesEveryAllowlistedSensitiveCategory() throws {
        let raw = "authorization: Bearer fixture-auth api_key=fixture-api wifi_ssid=FixtureNet "
            + "wifi_password=fixture-pass device_id=123e4567-e89b-12d3-a456-426614174000 "
            + "session_id=fixture-session /Users/fixture/Library/item 192.168.4.2 "
            + "02:00:00:12:34:56 https://fixture.invalid/api person@example.test "
            + "transcript=fixture private speech"

        let redacted = try M4DiagnosticRedactor.redact(line: raw)

        for forbidden in [
            "fixture-auth", "fixture-api", "FixtureNet", "fixture-pass",
            "123e4567-e89b-12d3-a456-426614174000", "fixture-session",
            "/Users/fixture", "192.168.4.2", "02:00:00:12:34:56",
            "https://fixture.invalid", "person@example.test", "fixture private speech",
        ] {
            #expect(!redacted.contains(forbidden))
        }
        #expect(redacted.contains("[REDACTED_CREDENTIAL]"))
        #expect(redacted.contains("[REDACTED_WIFI]"))
        #expect(redacted.contains("[REDACTED_IDENTITY]"))
        #expect(redacted.contains("[REDACTED_PATH]"))
        #expect(redacted.contains("[REDACTED_IP]"))
        #expect(redacted.contains("[REDACTED_MAC]"))
        #expect(redacted.contains("[REDACTED_ENDPOINT]"))
        #expect(redacted.contains("[REDACTED_SPEECH]"))

        let redactedJSON = try M4DiagnosticRedactor.redact(
            line: #"{"token":"json-secret","ssid":"JsonNet","text":"json speech"}"#
        )
        #expect(!redactedJSON.contains("json-secret"))
        #expect(!redactedJSON.contains("JsonNet"))
        #expect(!redactedJSON.contains("json speech"))
        #expect(redactedJSON.contains("[REDACTED_CREDENTIAL]"))
        #expect(redactedJSON.contains("[REDACTED_WIFI]"))
        #expect(redactedJSON.contains("[REDACTED_SPEECH]"))
    }

    @Test
    func redactorReplacesSystemPathsAndPairingIdentifiers() throws {
        let raw = "cache=/var/folders/fixture/session device=/dev/cu.usbmodem-fixture "
            + "pairing_id=fixture-pairing-id"

        let redacted = try M4DiagnosticRedactor.redact(line: raw)

        #expect(!redacted.contains("/var/folders/fixture/session"))
        #expect(!redacted.contains("/dev/cu.usbmodem-fixture"))
        #expect(!redacted.contains("fixture-pairing-id"))
        #expect(redacted.contains("[REDACTED_PATH]"))
        #expect(redacted.contains("[REDACTED_IDENTITY]"))
    }

    @Test
    func previewWithoutLogsNeverReadsALogSource() async throws {
        let reader = FictionalDiagnosticEvidenceReader(
            snapshot: fictionalSnapshot(),
            logs: fictionalLogs
        )

        let prepared = try await M4DiagnosticBundleBuilder(
            evidenceReader: reader
        ).prepare(includeRedactedLogs: false)

        #expect(prepared.manifest.schemaVersion == 1)
        #expect(prepared.manifest.entries.count == 3)
        #expect(prepared.files.count == 4)
        #expect(!prepared.manifest.includesRedactedLogExcerpts)
        #expect(!prepared.manifest.includesRawLogs)
        #expect(!prepared.manifest.uploadsAutomatically)
        #expect(await reader.logReadCount == 0)
        #expect(Set(prepared.files.map(\.relativePath)) == [
            "manifest-v1.json", "runtime-v1.json", "summary-v1.json", "system-v1.json",
        ])
    }

    @Test
    func previewWithLogsIsBoundedAndContainsOnlyRedactedExcerpts() async throws {
        var bridgeLines = Array(repeating: fictionalLogs[.bridge]![0], count: 250)
        bridgeLines.append(String(repeating: "x", count: 600))
        let reader = FictionalDiagnosticEvidenceReader(
            snapshot: fictionalSnapshot(),
            logs: [
                .bridge: bridgeLines,
                .hud: fictionalLogs[.hud]!,
            ]
        )

        let prepared = try await M4DiagnosticBundleBuilder(
            evidenceReader: reader
        ).prepare(includeRedactedLogs: true)

        #expect(prepared.manifest.entries.count == 5)
        #expect(prepared.files.count == 6)
        #expect(prepared.manifest.includesRedactedLogExcerpts)
        #expect(await reader.logReadCount == 2)
        for path in M4DiagnosticLogKind.allCases.map(\.relativePath) {
            let data = try #require(prepared.files.first { $0.relativePath == path }?.data)
            let text = String(decoding: data, as: UTF8.self)
            #expect(data.count <= M4DiagnosticLogExcerptBuilder.maximumOutputBytes)
            #expect(!text.contains("fixture-bridge-token"))
            #expect(!text.contains("fixture speech"))
            #expect(!text.contains("10.0.0.7"))
            #expect(text.contains("[REDACTED_"))
        }
    }

    @Test
    func invalidStructuredMetadataFailsBeforeAnyLogRead() async {
        let reader = FictionalDiagnosticEvidenceReader(
            snapshot: fictionalSnapshot(appVersion: "/Users/fixture/secret"),
            logs: fictionalLogs
        )

        await #expect(throws: M4DiagnosticExportError.invalidStructuredEvidence) {
            try await M4DiagnosticBundleBuilder(
                evidenceReader: reader
            ).prepare(includeRedactedLogs: true)
        }
        #expect(await reader.logReadCount == 0)
    }

    @Test
    func oversizedLogLineFailsClosedWithoutProducingAPreview() async {
        let reader = FictionalDiagnosticEvidenceReader(
            snapshot: fictionalSnapshot(),
            logs: [
                .bridge: [String(repeating: "z", count: M4DiagnosticRedactor.maximumInputLineBytes + 1)],
                .hud: [],
            ]
        )

        await #expect(throws: M4DiagnosticExportError.logLineTooLarge) {
            try await M4DiagnosticBundleBuilder(
                evidenceReader: reader
            ).prepare(includeRedactedLogs: true)
        }
    }

    @Test
    func foundationTransactionCreatesOnePrivateAtomicLocalBundle() async throws {
        let sandbox = makeTemporarySandbox()
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let prepared = try await makePreparedExport(includeLogs: true)
        let locations = try M4DiagnosticExportLocations.make(
            destinationDirectory: sandbox,
            exportIdentifier: "fixture-001"
        )
        let transaction = M4DiagnosticExportTransaction(
            locations: locations,
            fileSystem: try M4FoundationDiagnosticFileSystem(authorizedRoot: sandbox)
        )

        let receipt = try await transaction.export(
            prepared,
            authorization: M4DiagnosticExportAuthorization(
                confirmedManifest: prepared.manifest,
                destinationWasUserSelected: true
            )
        )

        #expect(receipt.bundleName == "VibeStick-Diagnostics-fixture-001.vibediagnostics")
        #expect(receipt.entryCount == 6)
        #expect(receipt.privatePermissionsValidated)
        #expect(!receipt.uploaded)
        #expect(!receipt.includesRawLogs)
        #expect(FileManager.default.fileExists(atPath: locations.finalDirectory.path))
        #expect(!FileManager.default.fileExists(atPath: locations.stagingDirectory.path))
        #expect(try permissions(at: locations.finalDirectory) == 0o700)
        for file in prepared.files {
            let url = locations.finalDirectory.appendingPathComponent(file.relativePath)
            #expect(try Data(contentsOf: url) == file.data)
            #expect(try permissions(at: url) == 0o600)
        }
        #expect(try permissions(at: locations.finalDirectory.appendingPathComponent("logs")) == 0o700)
    }

    @Test
    func unconfirmedManifestAndDestinationCannotTouchTheFilesystem() async throws {
        let prepared = try await makePreparedExport(includeLogs: false)
        let locations = try M4DiagnosticExportLocations.make(
            destinationDirectory: URL(fileURLWithPath: "/fixture/export-root"),
            exportIdentifier: "fixture-002"
        )
        let fileSystem = RecordingDiagnosticFileSystem()
        let transaction = M4DiagnosticExportTransaction(
            locations: locations,
            fileSystem: fileSystem
        )

        await #expect(throws: M4DiagnosticExportError.destinationWasNotUserSelected) {
            try await transaction.export(
                prepared,
                authorization: M4DiagnosticExportAuthorization(
                    confirmedManifest: prepared.manifest,
                    destinationWasUserSelected: false
                )
            )
        }
        var changedManifest = prepared.manifest
        changedManifest = M4DiagnosticManifestPreview(
            schemaVersion: changedManifest.schemaVersion,
            manifestRelativePath: changedManifest.manifestRelativePath,
            entries: changedManifest.entries,
            includesRedactedLogExcerpts: changedManifest.includesRedactedLogExcerpts,
            includesRawLogs: changedManifest.includesRawLogs,
            uploadsAutomatically: true
        )
        await #expect(throws: M4DiagnosticExportError.manifestConfirmationMismatch) {
            try await transaction.export(
                prepared,
                authorization: M4DiagnosticExportAuthorization(
                    confirmedManifest: changedManifest,
                    destinationWasUserSelected: true
                )
            )
        }
        #expect(await fileSystem.mutationCount == 0)
    }

    @Test
    func injectedWriteFailureRemovesPrivateStagingAndNeverPublishes() async throws {
        let prepared = try await makePreparedExport(includeLogs: false)
        let locations = try M4DiagnosticExportLocations.make(
            destinationDirectory: URL(fileURLWithPath: "/fixture/export-root"),
            exportIdentifier: "fixture-003"
        )
        let fileSystem = RecordingDiagnosticFileSystem(failOnWriteNumber: 2)
        let transaction = M4DiagnosticExportTransaction(
            locations: locations,
            fileSystem: fileSystem
        )

        await #expect(throws: M4DiagnosticExportError.stagingFailed) {
            try await transaction.export(
                prepared,
                authorization: M4DiagnosticExportAuthorization(
                    confirmedManifest: prepared.manifest,
                    destinationWasUserSelected: true
                )
            )
        }

        #expect(!(await fileSystem.itemExistsUnchecked(at: locations.stagingDirectory)))
        #expect(!(await fileSystem.itemExistsUnchecked(at: locations.finalDirectory)))
        #expect(await fileSystem.promotionCount == 0)
    }

    @Test
    func existingFinalBundleIsNeverOverwritten() async throws {
        let prepared = try await makePreparedExport(includeLogs: false)
        let locations = try M4DiagnosticExportLocations.make(
            destinationDirectory: URL(fileURLWithPath: "/fixture/export-root"),
            exportIdentifier: "fixture-004"
        )
        let fileSystem = RecordingDiagnosticFileSystem(existingDirectories: [locations.finalDirectory])
        let transaction = M4DiagnosticExportTransaction(
            locations: locations,
            fileSystem: fileSystem
        )

        await #expect(throws: M4DiagnosticExportError.bundleAlreadyExists) {
            try await transaction.export(
                prepared,
                authorization: M4DiagnosticExportAuthorization(
                    confirmedManifest: prepared.manifest,
                    destinationWasUserSelected: true
                )
            )
        }
        #expect(await fileSystem.mutationCount == 0)
        #expect(await fileSystem.itemExistsUnchecked(at: locations.finalDirectory))
    }

    @Test
    func productionFilesystemRejectsExistingSymlinkComponents() async throws {
        let sandbox = makeTemporarySandbox()
        let outside = makeTemporarySandbox()
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: sandbox)
            try? FileManager.default.removeItem(at: outside)
        }
        let linked = sandbox.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: outside)
        let fileSystem = try M4FoundationDiagnosticFileSystem(authorizedRoot: sandbox)

        #expect(throws: M4DiagnosticExportError.symbolicLinkInDestination) {
            try fileSystem.createPrivateDirectory(at: linked.appendingPathComponent("nested"))
        }
    }

    private var fictionalLogs: [M4DiagnosticLogKind: [String]] {
        [
            .bridge: [
                "bridge healthy token=fixture-bridge-token ip=10.0.0.7 transcript=fixture speech",
            ],
            .hud: [
                "hud healthy session_id=fixture-session /Users/fixture/Library/VibeStick",
            ],
        ]
    }

    private func fictionalSnapshot(
        appVersion: String = "0.2.0"
    ) -> M4DiagnosticStructuredSnapshot {
        M4DiagnosticStructuredSnapshot(
            appVersion: appVersion,
            appBuild: "9",
            operatingSystemVersion: "15.6",
            architecture: .arm64,
            components: M4DiagnosticComponent.allCases.map {
                M4DiagnosticComponentSummary(
                    component: $0,
                    healthy: true,
                    signatureValid: true
                )
            },
            launchAgents: M4DiagnosticComponent.allCases.map {
                M4DiagnosticLaunchAgentSummary(
                    component: $0,
                    loaded: $0 != .paste,
                    running: $0 != .paste,
                    ownedByCurrentUser: true
                )
            },
            bridgeHealth: .healthy,
            migrationReceipt: M4DiagnosticMigrationReceiptSummary(
                schemaVersion: 1,
                categories: [.runtimeComponents, .bridgeCredential, .asrCredential],
                completedOperations: [
                    .preparePrivateRollback,
                    .stageVersionedKeychainItems,
                    .validateStagedState,
                    .atomicallyCommitConfiguration,
                ],
                configurationCommitted: true,
                legacyFallbackRetained: true,
                legacyItemsDeleted: false,
                runtimeRestarted: false
            ),
            runtimeReceipt: M4DiagnosticRuntimeReceiptSummary(
                schemaVersion: 1,
                payloadVersion: "m4-5i",
                installed: true,
                rolledBack: false,
                preservedPasteIdentity: true
            )
        )
    }

    private func makePreparedExport(
        includeLogs: Bool
    ) async throws -> M4PreparedDiagnosticExport {
        try await M4DiagnosticBundleBuilder(
            evidenceReader: FictionalDiagnosticEvidenceReader(
                snapshot: fictionalSnapshot(),
                logs: fictionalLogs
            )
        ).prepare(includeRedactedLogs: includeLogs)
    }

    private func makeTemporarySandbox() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("VibeStick-M4-5J-\(UUID().uuidString)", isDirectory: true)
    }

    private func permissions(at url: URL) throws -> Int? {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue
    }
}

private actor FictionalDiagnosticEvidenceReader: M4DiagnosticEvidenceReading {
    private let snapshot: M4DiagnosticStructuredSnapshot
    private let logs: [M4DiagnosticLogKind: [String]]
    private(set) var logReadCount = 0

    init(
        snapshot: M4DiagnosticStructuredSnapshot,
        logs: [M4DiagnosticLogKind: [String]]
    ) {
        self.snapshot = snapshot
        self.logs = logs
    }

    func readStructuredSnapshot() -> M4DiagnosticStructuredSnapshot {
        snapshot
    }

    func readLogLines(for kind: M4DiagnosticLogKind) throws -> [String] {
        logReadCount += 1
        guard let lines = logs[kind] else { throw M4DiagnosticFixtureFailure.missingLog }
        return lines
    }
}

private actor RecordingDiagnosticFileSystem: M4DiagnosticFileSystemAccess {
    private var directories: Set<String>
    private var files: [String: Data] = [:]
    private var permissions: [String: Int] = [:]
    private let failOnWriteNumber: Int?
    private var writeCount = 0
    private(set) var mutationCount = 0
    private(set) var promotionCount = 0

    init(
        existingDirectories: [URL] = [],
        failOnWriteNumber: Int? = nil
    ) {
        directories = Set(existingDirectories.map(\.standardizedFileURL.path))
        self.failOnWriteNumber = failOnWriteNumber
    }

    func itemExists(at url: URL) -> Bool {
        itemExistsUnchecked(at: url)
    }

    func itemExistsUnchecked(at url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return directories.contains(path) || files[path] != nil
    }

    func createPrivateDirectory(at url: URL) {
        mutationCount += 1
        let path = url.standardizedFileURL.path
        directories.insert(path)
        permissions[path] = 0o700
    }

    func writePrivateFile(_ data: Data, to url: URL) throws {
        mutationCount += 1
        writeCount += 1
        if writeCount == failOnWriteNumber {
            throw M4DiagnosticFixtureFailure.injectedWrite
        }
        let path = url.standardizedFileURL.path
        files[path] = data
        permissions[path] = 0o600
    }

    func readFile(at url: URL) throws -> Data {
        guard let data = files[url.standardizedFileURL.path] else {
            throw M4DiagnosticFixtureFailure.missingFile
        }
        return data
    }

    func permissions(at url: URL) -> Int? {
        permissions[url.standardizedFileURL.path]
    }

    func relativeItems(at root: URL) -> [M4DiagnosticStoredItem] {
        let rootPath = root.standardizedFileURL.path + "/"
        var items: [M4DiagnosticStoredItem] = []
        for directory in directories where directory.hasPrefix(rootPath) {
            items.append(
                M4DiagnosticStoredItem(
                    relativePath: String(directory.dropFirst(rootPath.count)),
                    isDirectory: true,
                    permissions: permissions[directory]
                )
            )
        }
        for path in files.keys where path.hasPrefix(rootPath) {
            items.append(
                M4DiagnosticStoredItem(
                    relativePath: String(path.dropFirst(rootPath.count)),
                    isDirectory: false,
                    permissions: permissions[path]
                )
            )
        }
        return items.sorted { $0.relativePath < $1.relativePath }
    }

    func atomicallyPromoteDirectory(from source: URL, to destination: URL) throws {
        mutationCount += 1
        promotionCount += 1
        let sourcePath = source.standardizedFileURL.path
        let destinationPath = destination.standardizedFileURL.path
        guard directories.contains(sourcePath), !directories.contains(destinationPath) else {
            throw M4DiagnosticFixtureFailure.invalidPromotion
        }
        let directoryPaths = directories.filter {
            $0 == sourcePath || $0.hasPrefix(sourcePath + "/")
        }
        let filePaths = files.keys.filter { $0.hasPrefix(sourcePath + "/") }
        for path in directoryPaths {
            directories.remove(path)
            let newPath = destinationPath + String(path.dropFirst(sourcePath.count))
            directories.insert(newPath)
            permissions[newPath] = permissions.removeValue(forKey: path)
        }
        for path in filePaths {
            let newPath = destinationPath + String(path.dropFirst(sourcePath.count))
            files[newPath] = files.removeValue(forKey: path)
            permissions[newPath] = permissions.removeValue(forKey: path)
        }
    }

    func removeItem(at url: URL) {
        mutationCount += 1
        let path = url.standardizedFileURL.path
        directories = directories.filter { $0 != path && !$0.hasPrefix(path + "/") }
        for file in files.keys where file == path || file.hasPrefix(path + "/") {
            files.removeValue(forKey: file)
            permissions.removeValue(forKey: file)
        }
        for directory in permissions.keys where directory == path || directory.hasPrefix(path + "/") {
            permissions.removeValue(forKey: directory)
        }
    }
}

private enum M4DiagnosticFixtureFailure: Error {
    case missingLog
    case injectedWrite
    case missingFile
    case invalidPromotion
}
