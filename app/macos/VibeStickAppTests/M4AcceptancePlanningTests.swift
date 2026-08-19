import Testing

struct M4AcceptancePlanningTests {
    @Test
    func legacyPlanUsesOnlyCategoriesAndKeepsActivationSeparate() {
        let plan = M4LegacyMigrationPlanner.make(
            from: M4AcceptanceFixtures.fictionalLegacyDiscovery
        )

        #expect(plan.canOfferImport)
        #expect(plan.categories.count == M4LegacyConfigurationCategory.allCases.count)
        #expect(plan.steps.contains(.requestImportConfirmation))
        #expect(plan.steps.contains(.createPrivateRollbackSnapshot))
        #expect(plan.steps.contains(.stageKeychainItems))
        #expect(plan.steps.contains(.stageConfigurationFiles))
        #expect(plan.steps.contains(.preservePasteIdentity))
        #expect(plan.steps.contains(.requestRuntimeActivationConfirmation))
        #expect(plan.steps.contains(.recheckAccessibility))
        #expect(plan.preservesLegacyFiles)
        #expect(!plan.mayDeleteLegacyFiles)
        #expect(!plan.mayRestartRuntime)
    }

    @Test
    func legacyPlanFailsClosedForUnknownOwnershipOrActiveVoiceWork() {
        let plan = M4LegacyMigrationPlanner.make(
            from: M4AcceptanceFixtures.fictionalBlockedLegacyDiscovery
        )

        #expect(!plan.canOfferImport)
        #expect(plan.blockers == [.unknownRuntimeOwner, .activeVoiceWork])
        #expect(plan.steps == [.presentRedactedSummary])
    }

    @Test
    func diagnosticPlanContainsOnlySafeStructuredOrRedactedEntries() {
        let plan = M4DiagnosticPolicy.makePlan(includeRedactedLogs: true)

        #expect(plan.requiresExplicitExportConfirmation)
        #expect(!plan.uploadsAutomatically)
        #expect(!plan.includesRawLogs)
        #expect(plan.entries.allSatisfy {
            M4DiagnosticPolicy.permits($0.source)
                && M4DiagnosticPolicy.isSafeRelativePath($0.relativePath)
        })
        #expect(plan.entries.filter { $0.source == .redactedLogExcerpt }.count == 2)
    }

    @Test
    func diagnosticPolicyRejectsEveryFictionalPrivateSource() {
        #expect(
            M4AcceptanceFixtures.forbiddenDiagnosticSourceNames.allSatisfy {
                M4DiagnosticPolicy.forbiddenSourceNames.contains($0)
            }
        )
        #expect(!M4DiagnosticPolicy.permits(.rawEnvironment))
        #expect(!M4DiagnosticPolicy.permits(.rawPreferences))
        #expect(!M4DiagnosticPolicy.permits(.rawDeviceRegistry))
        #expect(!M4DiagnosticPolicy.permits(.rawRecording))
        #expect(!M4DiagnosticPolicy.permits(.rawLog))
        #expect(!M4DiagnosticPolicy.permits(.keychainValue))
        #expect(!M4DiagnosticPolicy.permits(.firmwareBackup))
        #expect(!M4DiagnosticPolicy.permits(.firmwareTransaction))
    }

    @Test
    func diagnosticPathsRejectAbsoluteTraversalAndAmbiguousComponents() {
        #expect(!M4DiagnosticPolicy.isSafeRelativePath("/tmp/summary.json"))
        #expect(!M4DiagnosticPolicy.isSafeRelativePath("../summary.json"))
        #expect(!M4DiagnosticPolicy.isSafeRelativePath("logs/../summary.json"))
        #expect(!M4DiagnosticPolicy.isSafeRelativePath("logs/./bridge.txt"))
        #expect(!M4DiagnosticPolicy.isSafeRelativePath("logs//bridge.txt"))
        #expect(!M4DiagnosticPolicy.isSafeRelativePath("logs\\bridge.txt"))
    }

    @Test
    func cleanMachineReadinessCannotUseDeveloperDependencies() {
        let missing = M4CleanMachineReadinessPlanner.blockers(
            for: M4AcceptanceFixtures.fictionalCleanMachineWithoutRuntime
        )
        let ready = M4CleanMachineReadinessPlanner.blockers(
            for: M4AcceptanceFixtures.fictionalReadyCleanMachine
        )

        #expect(missing == [.bundledRuntimeMissing, .externalInterpreterRequired])
        #expect(ready.isEmpty)
    }

    @Test
    func everyAuthorizationGateImpliesOnlyItself() {
        #expect(M4AuthorizationGate.allCases.allSatisfy {
            $0.impliedAuthorizations == [$0]
        })
    }
}
