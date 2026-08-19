import Foundation
import Testing

struct M4DiagnosticUIFlowTests {
    @MainActor
    @Test
    func initializationIsInertUntilAnExplicitPreviewRequest() async throws {
        let operation = DiagnosticOperationStub(prepared: try await preparedExport())
        let builder = DiagnosticOperationBuilderStub(operation: operation)
        let selector = DiagnosticDestinationSelectorStub(responses: [])
        let flow = M4DiagnosticUIFlow(builder: builder, destinationSelector: selector)

        #expect(flow.state == .idle)
        #expect(!flow.includesRedactedLogs)
        #expect(builder.makeCount == 0)
        #expect(selector.selectCount == 0)
        #expect(await operation.prepareCount == 0)
        #expect(await operation.exportCount == 0)
    }

    @MainActor
    @Test
    func explicitPreviewPublishesOnlyTheFixedManifestAndNoDestination() async throws {
        let operation = DiagnosticOperationStub(prepared: try await preparedExport())
        let builder = DiagnosticOperationBuilderStub(operation: operation)
        let selector = DiagnosticDestinationSelectorStub(responses: [])
        let flow = M4DiagnosticUIFlow(builder: builder, destinationSelector: selector)

        await flow.preparePreview()

        let review = try #require(reviewing(flow.state))
        #expect(builder.makeCount == 1)
        #expect(await operation.prepareRequests == [false])
        #expect(!review.destinationSelected)
        #expect(review.preview.schemaVersion == 1)
        #expect(review.preview.entries.count == 3)
        #expect(Set(review.preview.entries.map(\.relativePath)) == [
            "runtime-v1.json", "summary-v1.json", "system-v1.json",
        ])
        #expect(!review.preview.includesRawLogs)
        #expect(!review.preview.uploadsAutomatically)
        #expect(selector.selectCount == 0)
        #expect(!flow.requestFinalConfirmation())
        #expect(await operation.exportCount == 0)
    }

    @MainActor
    @Test
    func logChoiceIsFrozenWhenPreviewStartsAndPublishedContentIsRedacted() async throws {
        let reader = DiagnosticFixtureEvidenceReader(
            snapshot: fictionalSnapshot(),
            logs: [
                .bridge: ["token=fixture-secret transcript=fixture speech 10.0.0.9"],
                .hud: ["session_id=fixture-session /Users/fixture/private"],
            ]
        )
        let operation = M4LiveDiagnosticUIOperation(evidenceReader: reader)
        let builder = DiagnosticOperationBuilderStub(operation: operation)
        let flow = M4DiagnosticUIFlow(
            builder: builder,
            destinationSelector: DiagnosticDestinationSelectorStub(responses: [])
        )

        flow.setIncludesRedactedLogs(true)
        await flow.preparePreview()
        flow.setIncludesRedactedLogs(false)

        let review = try #require(reviewing(flow.state))
        #expect(flow.includesRedactedLogs)
        #expect(review.preview.includesRedactedLogExcerpts)
        #expect(review.preview.entries.count == 5)
        let published = String(describing: flow.state)
        #expect(!published.contains("fixture-secret"))
        #expect(!published.contains("fixture speech"))
        #expect(!published.contains("/Users/fixture"))
        #expect(!published.contains("10.0.0.9"))
        #expect(await reader.logReadCount == 2)
    }

    @MainActor
    @Test
    func cancellingDestinationSelectionDoesNotArmOrExport() async throws {
        let operation = DiagnosticOperationStub(prepared: try await preparedExport())
        let selector = DiagnosticDestinationSelectorStub(responses: [nil])
        let flow = M4DiagnosticUIFlow(
            builder: DiagnosticOperationBuilderStub(operation: operation),
            destinationSelector: selector
        )

        await flow.preparePreview()
        await flow.selectDestination()

        let review = try #require(reviewing(flow.state))
        #expect(!review.destinationSelected)
        #expect(selector.selectCount == 1)
        #expect(!flow.requestFinalConfirmation())
        #expect(await operation.exportCount == 0)
    }

    @MainActor
    @Test
    func selectedDestinationStaysPrivateAndConfirmationCanBeCancelled() async throws {
        let operation = DiagnosticOperationStub(prepared: try await preparedExport())
        let selected = URL(fileURLWithPath: "/fixture/private-export-location")
        let flow = M4DiagnosticUIFlow(
            builder: DiagnosticOperationBuilderStub(operation: operation),
            destinationSelector: DiagnosticDestinationSelectorStub(responses: [selected])
        )

        await flow.preparePreview()
        await flow.selectDestination()
        #expect(flow.requestFinalConfirmation())
        #expect(flow.isAwaitingFinalConfirmation)
        #expect(!String(describing: flow.state).contains(selected.path))
        #expect(!flow.finalConfirmationSummary!.redactedMessage.contains(selected.path))

        flow.cancelFinalConfirmation()

        let review = try #require(reviewing(flow.state))
        #expect(review.destinationSelected)
        #expect(await operation.exportCount == 0)
    }

    @MainActor
    @Test
    func confirmedExportUsesThePreparedManifestAndSelectedDirectoryOnce() async throws {
        let prepared = try await preparedExport(includeLogs: true)
        let operation = DiagnosticOperationStub(prepared: prepared)
        let selected = URL(fileURLWithPath: "/fixture/export-root")
        let flow = M4DiagnosticUIFlow(
            builder: DiagnosticOperationBuilderStub(operation: operation),
            destinationSelector: DiagnosticDestinationSelectorStub(responses: [selected])
        )

        flow.setIncludesRedactedLogs(true)
        await flow.preparePreview()
        await flow.selectDestination()
        #expect(flow.requestFinalConfirmation())
        await flow.confirmExport()

        #expect(await operation.exportCount == 1)
        #expect(await operation.exportDestinations == [selected])
        #expect(await operation.exportedManifests == [prepared.manifest])
        guard case let .completed(receipt) = flow.state else {
            Issue.record("expected completed diagnostic export")
            return
        }
        #expect(receipt.privatePermissionsValidated)
        #expect(!receipt.uploaded)
        #expect(!receipt.includesRawLogs)
        #expect(!String(describing: flow.state).contains(selected.path))
    }

    @MainActor
    @Test
    func preparationAndExportFailuresPublishOnlyFixedCategories() async throws {
        let prepared = try await preparedExport()
        let previewFailure = DiagnosticOperationStub(
            prepared: prepared,
            failure: .prepare
        )
        let previewFlow = M4DiagnosticUIFlow(
            builder: DiagnosticOperationBuilderStub(operation: previewFailure),
            destinationSelector: DiagnosticDestinationSelectorStub(responses: [])
        )
        await previewFlow.preparePreview()
        #expect(previewFlow.state == .failed(.previewFailed))
        #expect(!String(describing: previewFlow.state).contains("fixture-underlying-secret"))

        let exportFailure = DiagnosticOperationStub(
            prepared: prepared,
            failure: .export
        )
        let exportFlow = M4DiagnosticUIFlow(
            builder: DiagnosticOperationBuilderStub(operation: exportFailure),
            destinationSelector: DiagnosticDestinationSelectorStub(
                responses: [URL(fileURLWithPath: "/fixture/export-root")]
            )
        )
        await exportFlow.preparePreview()
        await exportFlow.selectDestination()
        #expect(exportFlow.requestFinalConfirmation())
        await exportFlow.confirmExport()
        #expect(exportFlow.state == .failed(.exportFailed))
        #expect(!String(describing: exportFlow.state).contains("fixture-underlying-secret"))
    }

    @Test
    func productionLogAdapterRequestsOnlyFourFixedBoundedSources() async throws {
        let fileReader = RecordingBoundedFileReader(
            files: [
                "bridge.log": "bridge token=fixture-one\n",
                "bridge.err.log": "bridge error fixture-two\n",
                "hud.log": "hud transcript=fixture speech\n",
                "hud.err.log": "hud session_id=fixture-session\n",
            ]
        )
        let root = URL(fileURLWithPath: "/fixture/support", isDirectory: true)
        let logReader = M4ProductionDiagnosticLogSourceReader(
            supportDirectory: root,
            fileReader: fileReader
        )
        let evidence = M4ProductionDiagnosticEvidenceReader(
            snapshotReader: M4DiagnosticSnapshotStore(snapshot: fictionalSnapshot()),
            logReader: logReader
        )

        let prepared = try await M4DiagnosticBundleBuilder(
            evidenceReader: evidence
        ).prepare(includeRedactedLogs: true)

        #expect(Set(await fileReader.requestedNames) == [
            "bridge.log", "bridge.err.log", "hud.log", "hud.err.log",
        ])
        #expect(Set(await fileReader.requestedMaximumBytes) == [
            M4ProductionDiagnosticLogSourceReader.maximumBytesPerFile,
        ])
        let logText = prepared.files
            .filter { $0.source == .redactedLogExcerpt }
            .map { String(decoding: $0.data, as: UTF8.self) }
            .joined()
        #expect(!logText.contains("fixture-one"))
        #expect(!logText.contains("fixture speech"))
        #expect(!logText.contains("fixture-session"))
        #expect(logText.contains("[REDACTED_"))
    }

    @Test
    func foundationLogAdapterReadsOnlyABoundedFictionalTailAndRejectsSymlinks() async throws {
        let root = temporaryDirectory("support")
        let outside = temporaryDirectory("outside")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let lines = (0..<300).map { "line-\($0) token=fixture-\($0)" }.joined(separator: "\n")
        try Data((lines + "\n").utf8).write(to: root.appendingPathComponent("bridge.log"))
        let logReader = M4ProductionDiagnosticLogSourceReader(supportDirectory: root)

        let readLines = try await logReader.readLogLines(for: .bridge)

        #expect(readLines.count <= M4ProductionDiagnosticLogSourceReader.maximumCombinedLines)
        #expect(readLines.last?.contains("line-299") == true)
        #expect(!readLines.contains { $0.contains("line-0 ") })

        let outsideLog = outside.appendingPathComponent("hud.log")
        try Data("fixture\n".utf8).write(to: outsideLog)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("hud.log"),
            withDestinationURL: outsideLog
        )
        await #expect(throws: M4DiagnosticEvidenceAdapterError.invalidFileType) {
            try await logReader.readLogLines(for: .hud)
        }
    }

    @Test
    func structuredSnapshotFactoryDropsRuntimeDetailsAndBridgeIdentity() throws {
        let bridge = BridgeSnapshot(
            health: BridgeHealthDTO(
                ok: true,
                bridgeName: "vibestick-bridge",
                bridgeVersion: "0.2.0",
                protocolVersion: 2,
                voiceInteractionVersion: 2,
                bridgeID: "fixture-private-bridge-identity"
            ),
            state: nil,
            healthEndpointResponded: true,
            errorMessage: "fixture-private-bridge-error",
            checkedAt: .distantPast
        )
        let runtime = RuntimeSnapshot(
            bridge: ComponentHealth(
                kind: .bridge,
                phase: .healthy,
                detail: "/Users/fixture/private bridge detail",
                isInstalled: true
            ),
            hud: ComponentHealth(
                kind: .hud,
                phase: .healthy,
                detail: "fixture-private-hud-detail",
                isInstalled: true
            ),
            paste: ComponentHealth(
                kind: .paste,
                phase: .permissionMissing,
                detail: "fixture-private-paste-detail",
                isInstalled: true
            ),
            isRecordingActive: false,
            checkedAt: .distantPast
        )

        let snapshot = M4DiagnosticAppSnapshotFactory.make(
            appVersion: "0.2.0",
            appBuild: "9",
            bridge: bridge,
            runtime: runtime,
            migrationReceipt: nil,
            runtimeReceipt: nil
        )
        let encoded = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)

        #expect(snapshot.bridgeHealth == .healthy)
        #expect(snapshot.components.count == 3)
        #expect(snapshot.launchAgents.count == 3)
        #expect(!encoded.contains("fixture-private"))
        #expect(!encoded.contains("/Users/fixture"))
        #expect(!encoded.contains("bridge-identity"))
    }

    @Test
    func structuredSnapshotReadDoesNotReadAnyLogSource() async throws {
        let logReader = CountingLogSourceReader()
        let evidence = M4ProductionDiagnosticEvidenceReader(
            snapshotReader: M4DiagnosticSnapshotStore(snapshot: fictionalSnapshot()),
            logReader: logReader
        )

        _ = try await evidence.readStructuredSnapshot()

        #expect(await logReader.readCount == 0)
    }

    @Test
    func productionEvidenceUsesOnlyInjectedSignatureBooleans() async throws {
        let signatureReader = FixtureSignatureReader(values: [
            .bridge: true,
            .hud: false,
            .paste: true,
        ])
        let evidence = M4ProductionDiagnosticEvidenceReader(
            snapshotReader: M4DiagnosticSnapshotStore(snapshot: fictionalSnapshot()),
            logReader: CountingLogSourceReader(),
            signatureReader: signatureReader
        )

        let snapshot = try await evidence.readStructuredSnapshot()

        #expect(await signatureReader.readCount == 1)
        #expect(Dictionary(uniqueKeysWithValues: snapshot.components.map {
            ($0.component, $0.signatureValid)
        }) == [
            .bridge: true,
            .hud: false,
            .paste: true,
        ])
    }

    private func preparedExport(
        includeLogs: Bool = false
    ) async throws -> M4PreparedDiagnosticExport {
        try await M4DiagnosticBundleBuilder(
            evidenceReader: DiagnosticFixtureEvidenceReader(
                snapshot: fictionalSnapshot(),
                logs: [
                    .bridge: ["token=fixture-secret"],
                    .hud: ["transcript=fixture speech"],
                ]
            )
        ).prepare(includeRedactedLogs: includeLogs)
    }

    private func reviewing(_ state: M4DiagnosticUIState) -> M4DiagnosticUIReview? {
        guard case let .reviewing(review) = state else { return nil }
        return review
    }

    private func fictionalSnapshot() -> M4DiagnosticStructuredSnapshot {
        M4DiagnosticStructuredSnapshot(
            appVersion: "0.2.0",
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
            migrationReceipt: nil,
            runtimeReceipt: nil
        )
    }

    private func temporaryDirectory(_ label: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "VibeStick-M4-5K-\(label)-\(UUID().uuidString)",
            isDirectory: true
        )
    }
}

private actor DiagnosticFixtureEvidenceReader: M4DiagnosticEvidenceReading {
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

    func readLogLines(for kind: M4DiagnosticLogKind) -> [String] {
        logReadCount += 1
        return logs[kind] ?? []
    }
}

private enum DiagnosticOperationFailure: Error {
    case prepare
    case export

    var underlyingDetail: String { "fixture-underlying-secret" }
}

private actor DiagnosticOperationStub: M4DiagnosticUIOperating {
    enum Failure: Equatable {
        case prepare
        case export
    }

    private let prepared: M4PreparedDiagnosticExport
    private let failure: Failure?
    private(set) var prepareRequests: [Bool] = []
    private(set) var exportDestinations: [URL] = []
    private(set) var exportedManifests: [M4DiagnosticManifestPreview] = []

    init(
        prepared: M4PreparedDiagnosticExport,
        failure: Failure? = nil
    ) {
        self.prepared = prepared
        self.failure = failure
    }

    var prepareCount: Int { prepareRequests.count }
    var exportCount: Int { exportDestinations.count }

    func prepare(includeRedactedLogs: Bool) throws -> M4PreparedDiagnosticExport {
        prepareRequests.append(includeRedactedLogs)
        if failure == .prepare { throw DiagnosticOperationFailure.prepare }
        return prepared
    }

    func export(
        prepared: M4PreparedDiagnosticExport,
        destinationDirectory: URL
    ) throws -> M4DiagnosticExportReceipt {
        exportDestinations.append(destinationDirectory)
        exportedManifests.append(prepared.manifest)
        if failure == .export { throw DiagnosticOperationFailure.export }
        return M4DiagnosticExportReceipt(
            bundleName: "VibeStick-Diagnostics-fixture.vibediagnostics",
            entryCount: prepared.files.count,
            privatePermissionsValidated: true,
            uploaded: false,
            includesRawLogs: false
        )
    }
}

private final class DiagnosticOperationBuilderStub:
    M4DiagnosticUIOperationBuilding,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let operation: any M4DiagnosticUIOperating
    private var count = 0

    init(operation: any M4DiagnosticUIOperating) {
        self.operation = operation
    }

    var makeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func makeOperation() -> any M4DiagnosticUIOperating {
        lock.lock()
        count += 1
        lock.unlock()
        return operation
    }
}

@MainActor
private final class DiagnosticDestinationSelectorStub: M4DiagnosticDestinationSelecting {
    private var responses: [URL?]
    private(set) var selectCount = 0

    init(responses: [URL?]) {
        self.responses = responses
    }

    func selectDestination() async -> URL? {
        selectCount += 1
        guard !responses.isEmpty else { return nil }
        return responses.removeFirst()
    }
}

private actor RecordingBoundedFileReader: M4DiagnosticBoundedFileReading {
    private let files: [String: String]
    private(set) var requestedNames: [String] = []
    private(set) var requestedMaximumBytes: [Int] = []

    init(files: [String: String]) {
        self.files = files
    }

    func readTail(at url: URL, maximumBytes: Int) -> M4DiagnosticTailData? {
        requestedNames.append(url.lastPathComponent)
        requestedMaximumBytes.append(maximumBytes)
        guard let value = files[url.lastPathComponent] else { return nil }
        return M4DiagnosticTailData(
            data: Data(value.utf8),
            startedAfterBeginning: false
        )
    }
}

private actor CountingLogSourceReader: M4DiagnosticLogSourceReading {
    private(set) var readCount = 0

    func readLogLines(for kind: M4DiagnosticLogKind) -> [String] {
        readCount += 1
        return []
    }
}

private actor FixtureSignatureReader: M4DiagnosticComponentSignatureReading {
    private let values: [M4DiagnosticComponent: Bool]
    private(set) var readCount = 0

    init(values: [M4DiagnosticComponent: Bool]) {
        self.values = values
    }

    func readSignatureValidity() -> [M4DiagnosticComponent: Bool] {
        readCount += 1
        return values
    }
}
