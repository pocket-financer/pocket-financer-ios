import Foundation
import SwiftData
import SwiftUI
import XCTest

@testable import PocketFinancer

final class AppStartupAndStorageTests: XCTestCase {
    /// Production keeps its database alive for the process lifetime. Keep a successfully
    /// opened compatibility fixture alive too, because iOS 26 SwiftData can abort if a
    /// freshly opened `ModelContainer` is released while its startup notifications drain.
    @MainActor private static var retainedCompatibleStores: [(AppDatabase, URL)] = []

    func testAppDeclaresUSEnglishAsItsDevelopmentLocalization() {
        XCTAssertEqual(Bundle.main.developmentLocalization, "en-US")
    }

    @MainActor
    func testPendingDrainRequiresCompletedOnboardingAndActiveScene() {
        XCTAssertTrue(
            PendingAlertDrainPolicy.mayDrain(
                completedOnboarding: true,
                scenePhase: .active
            )
        )
        for phase in [ScenePhase.inactive, .background] {
            XCTAssertFalse(
                PendingAlertDrainPolicy.mayDrain(
                    completedOnboarding: true,
                    scenePhase: phase
                )
            )
        }
        XCTAssertFalse(
            PendingAlertDrainPolicy.mayDrain(
                completedOnboarding: false,
                scenePhase: .active
            )
        )
    }

    @MainActor
    func testBootstrapDefersDatabaseOpenUntilItsLoadingTaskRuns() {
        var openCount = 0

        _ = StoreBootstrapView(openDatabase: {
            openCount += 1
            throw AppDatabaseStartupFailure(
                kind: .storeOpenFailed,
                diagnosticCode: "StoreInitializationError/91"
            )
        })

        XCTAssertEqual(openCount, 0)
    }

    func testStartupFailureClassifiesUnrecognizedNewerProtectedAndUnknownErrorsSafely() {
        let sensitiveDescription = "Store at /private/example contained a sensitive alert body"
        let modelError = NSError(
            domain: NSCocoaErrorDomain,
            code: 134_504,
            userInfo: [NSLocalizedDescriptionKey: sensitiveDescription]
        )
        let outerError = NSError(
            domain: NSCocoaErrorDomain,
            code: 134_080,
            userInfo: [NSUnderlyingErrorKey: modelError]
        )
        let unrecognized = AppDatabaseStartupFailure(classifying: outerError, phase: .openingStore)
        XCTAssertEqual(unrecognized.kind, .unrecognizedStoreModel)
        XCTAssertEqual(unrecognized.safeCode, "store_model_unrecognized")
        XCTAssertEqual(unrecognized.diagnosticCode, "NSCocoaErrorDomain/134504")
        XCTAssertFalse(String(describing: unrecognized).contains(sensitiveDescription))

        let newerError = NSError(domain: NSCocoaErrorDomain, code: 134_506)
        let newer = AppDatabaseStartupFailure(classifying: newerError, phase: .openingStore)
        XCTAssertEqual(newer.kind, .newerStoreVersion)
        XCTAssertEqual(newer.safeCode, "store_created_by_newer_version")
        XCTAssertEqual(newer.diagnosticCode, "NSCocoaErrorDomain/134506")

        let posixProtected = NSError(domain: NSPOSIXErrorDomain, code: 13)
        let protected = AppDatabaseStartupFailure(classifying: posixProtected, phase: .openingStore)
        XCTAssertEqual(protected.kind, .protectedDataUnavailable)
        XCTAssertEqual(protected.safeCode, "protected_data_unavailable")
        XCTAssertEqual(protected.diagnosticCode, "NSPOSIXErrorDomain/13")

        let cocoaProtected = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
        let protectedCocoa = AppDatabaseStartupFailure(classifying: cocoaProtected, phase: .openingStore)
        XCTAssertEqual(protectedCocoa.kind, .protectedDataUnavailable)

        let unknownDomain = NSError(
            domain: "private.store.path.and.vendor.details",
            code: 91,
            userInfo: [NSLocalizedDescriptionKey: "private message body"]
        )
        let storeOpen = AppDatabaseStartupFailure(classifying: unknownDomain, phase: .openingStore)
        XCTAssertEqual(storeOpen.kind, .storeOpenFailed)
        XCTAssertEqual(storeOpen.diagnosticCode, "StoreInitializationError/91")
        XCTAssertFalse(storeOpen.diagnosticCode.contains(unknownDomain.domain))
        XCTAssertFalse(String(describing: storeOpen).contains("private message body"))

        let protectionFallback = AppDatabaseStartupFailure(
            classifying: unknownDomain,
            phase: .applyingFileProtection
        )
        XCTAssertEqual(protectionFallback.kind, .fileProtectionFailed)
        XCTAssertEqual(protectionFallback.safeCode, "file_protection_failed")
    }

    func testSecureStoreFilePolicyExcludesStoreDirectoryAndSidecarFilesFromBackups() throws {
        let directoryURL = FileManager.default.temporaryDirectory.appending(
            path: "PocketFinancerPolicy-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        try SecureStoreFilePolicy.prepareDirectory(directoryURL)
        let storeURL = directoryURL.appending(path: "PocketFinancer.store")
        let walURL = URL(filePath: storeURL.path + "-wal")
        let shmURL = URL(filePath: storeURL.path + "-shm")
        for fileURL in [storeURL, walURL, shmURL] {
            XCTAssertTrue(FileManager.default.createFile(atPath: fileURL.path, contents: Data()))
        }

        try SecureStoreFilePolicy.applyToStoreFiles(at: storeURL)

        for targetURL in [directoryURL, storeURL, walURL, shmURL] {
            let values = try targetURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
            XCTAssertEqual(values.isExcludedFromBackup, true)
        }
    }

    @MainActor
    func testLiveIngestionAndEnqueueFailClosedWhenStoreIsUnavailable() async {
        await TestFixtures.assertThrowsErrorAsync {
            _ = try await AlertIngestionService.ingestLive(
                body: TestFixtures.validBody,
                sender: "SYNTHETIC-SENDER",
                receivedAt: TestFixtures.receivedAt,
                sourceApplication: "Messages",
                origin: .shortcut,
                openDatabase: {
                    throw AppDatabaseStartupFailure(
                        kind: .storeOpenFailed,
                        diagnosticCode: "StoreInitializationError/91"
                    )
                }
            )
        } verify: { error in
            XCTAssertEqual(error as? AlertIngestionError, .storeUnavailable)
        }

        await TestFixtures.assertThrowsErrorAsync {
            _ = try await AlertIngestionService.enqueueLive(
                body: TestFixtures.validBody,
                sender: "SYNTHETIC-SENDER",
                receivedAt: TestFixtures.receivedAt,
                sourceApplication: "Messages",
                origin: .shortcut,
                openDatabase: {
                    throw AppDatabaseStartupFailure(
                        kind: .protectedDataUnavailable,
                        diagnosticCode: "NSPOSIXErrorDomain/13"
                    )
                }
            )
        } verify: { error in
            XCTAssertEqual(error as? AlertIngestionError, .storeUnavailable)
        }
    }

    func testIntentErrorsExplicitlyStateAlertWasNotSavedWithoutLeakingContent() {
        for error in [
            ImportTransactionAlertIntentError.localStoreUnavailable,
            .notSaved,
        ] {
            let message = error.errorDescription ?? ""
            XCTAssertTrue(message.contains("This alert was not saved"))
            XCTAssertTrue(message.contains("Open Pocket Financer"))
            XCTAssertFalse(message.contains(TestFixtures.validBody))
            XCTAssertFalse(message.contains("SYNTHETIC-SENDER"))
        }
    }

    @MainActor
    func testLocalDataServiceDiagnosticsAndEraseAllCoverEveryPersistedModel() throws {
        let database = try AppDatabase(inMemory: true)
        let context = database.container.mainContext

        let statuses: [AlertStatus] = [
            .pending,
            .processing,
            .needsReview,
            .imported,
            .rejected,
            .duplicate,
        ]
        var insertedAlerts: [InboxAlert] = []
        for status in statuses {
            let alert = TestFixtures.makeAlert(body: "Synthetic \(status.rawValue)")
            alert.status = status
            context.insert(alert)
            insertedAlerts.append(alert)
        }
        let alert = try XCTUnwrap(insertedAlerts.first)
        let account = Account(
            name: "Synthetic Account",
            bank: "Synthetic Bank",
            kind: .account,
            suffix: "1234",
            now: TestFixtures.receivedAt
        )
        let transaction = PocketFinancer.Transaction(
            amountMinorUnits: 50_000,
            currencyCode: "INR",
            merchant: "Demo Store",
            occurredAt: TestFixtures.receivedAt,
            direction: .debit,
            accountID: account.id,
            accountLabel: account.name,
            parserName: SmsContractAssets.releaseID,
            reviewState: .confirmed,
            sourceAlertID: alert.id,
            amountEvidenceText: "INR 500.00",
            dateEvidenceText: nil,
            now: TestFixtures.receivedAt
        )
        let run = ExtractionRun(
            alertID: alert.id,
            attemptIndex: 1,
            startedAt: TestFixtures.receivedAt,
            parserName: "Legacy",
            contractVersion: "v1",
            profileVersion: "1",
            localeIdentifier: "en-US",
            localeWasSupported: true,
            supportedLanguageIdentifiers: ["en"],
            exactInstructions: "Instructions",
            exactRequest: "Request"
        )
        let operation = SmsProcessingOperation(
            sourceAlertID: alert.id,
            trigger: "manual",
            configurationJSON: "{}",
            configurationHash: String(repeating: "a", count: 64),
            contractReleaseID: SmsContractAssets.releaseID
        )
        context.insert(account)
        context.insert(transaction)
        context.insert(run)
        context.insert(
            StructuredGenerationSnapshot(
                extractionRunID: run.id,
                sequenceIndex: 0,
                capturedAt: TestFixtures.receivedAt,
                rawContentJSON: "{}",
                isComplete: true
            )
        )
        context.insert(
            DeterministicFilterRun(
                alertID: alert.id,
                evaluationIndex: 0,
                evaluatedAt: TestFixtures.receivedAt,
                rulesVersion: "1",
                decisionRawValue: "eligible",
                rejectionCodeRawValue: nil,
                completedStages: ["nonEmptyBody"],
                senderWasUsed: false,
                stagesJSON: "[]"
            )
        )
        context.insert(
            SmsSourceMetadataEvent(
                sourceAlertID: alert.id,
                sequence: 0,
                kind: "admission",
                payloadJSON: "{}"
            )
        )
        context.insert(operation)
        context.insert(
            SmsProcessingAnalysis(
                operationID: operation.id,
                analysisID: "an-1",
                contractVersion: "pocketfinancer.sms-analysis/2",
                sourceHash: String(repeating: "b", count: 64),
                configurationHash: operation.configurationHash,
                canonicalJSON: "{}"
            )
        )
        context.insert(
            SmsSelectorAttempt(
                operationID: operation.id,
                attemptIndex: 0,
                runtimeProfileJSON: "{}",
                requestJSON: "{}"
            )
        )
        context.insert(
            SmsProcessingTraceEvent(
                operationID: operation.id,
                sequence: 0,
                stage: "claim",
                status: "completed",
                eventHash: String(repeating: "c", count: 64)
            )
        )
        context.insert(
            SmsReconstructedResult(
                operationID: operation.id,
                contractVersion: "pocketfinancer.processing-result/3",
                recognitionDecision: "posted",
                semanticResultJSON: "{}"
            )
        )
        context.insert(
            SmsPersistenceDecision(
                operationID: operation.id,
                result: "eligible",
                primaryReason: "persistence_all_gates_passed",
                checksJSON: "[]",
                accountResolutionJSON: "{}",
                rolloutMode: "automatic"
            )
        )
        context.insert(
            SmsReviewCase(
                sourceAlertID: alert.id,
                currentOperationID: operation.id,
                reasonCodes: ["account_resolution_unresolved"]
            )
        )
        context.insert(
            SmsUserFeedbackEvent(
                actionID: UUID(),
                reviewCaseID: nil,
                operationID: operation.id,
                transactionID: transaction.id,
                transactionRevisionID: nil,
                expectedReviewRevision: 0,
                resultingReviewRevision: 1,
                action: "confirm",
                actorClass: "user",
                correctionsJSON: "[]",
                retryConfiguration: nil,
                previousEventHash: nil,
                eventHash: String(repeating: "d", count: 64)
            )
        )
        context.insert(
            SmsTransactionRevision(
                transactionID: transaction.id,
                sourceAlertID: alert.id,
                stableEventID: operation.stableEventID,
                revision: 0,
                previousRevisionID: nil,
                operationID: operation.id,
                feedbackActionID: nil,
                amountMinorUnits: 50_000,
                currencyCode: "INR",
                currencyScale: 2,
                direction: "debit",
                merchant: "Demo Store",
                accountID: account.id,
                occurredAt: TestFixtures.receivedAt,
                provenance: "automatic_grounded_extraction",
                isCurrentProjection: true
            )
        )
        context.insert(
            SmsAccountAlias(
                accountID: account.id,
                normalizedAliasHash: CanonicalJSON.sha256("suffix:1234"),
                aliasKind: "suffix",
                matchingScope: "owned_account_v1",
                confirmedByUser: true
            )
        )
        context.insert(SmsLegacyTransactionSnapshot(transaction: transaction))
        context.insert(
            SmsTraceImportReceipt(
                transferID: UUID(),
                manifestHash: String(repeating: "e", count: 64),
                sourcePlatform: "ios",
                consentedAt: TestFixtures.receivedAt,
                operationCount: 1,
                provenance: "test"
            )
        )
        context.insert(SmsContractReleaseState(releaseID: SmsContractAssets.releaseID))
        try context.save()

        let service = LocalDataService(context: context)
        XCTAssertEqual(
            service.diagnostics(),
            StorageDiagnostic(pending: 2, needsReview: 1, imported: 1, rejected: 1, duplicates: 1)
        )

        try service.eraseAll()

        XCTAssertEqual(
            service.diagnostics(),
            StorageDiagnostic(pending: 0, needsReview: 0, imported: 0, rejected: 0, duplicates: 0)
        )
        XCTAssertTrue(try context.fetch(FetchDescriptor<InboxAlert>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<PocketFinancer.Transaction>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<Account>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<ExtractionRun>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<StructuredGenerationSnapshot>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<DeterministicFilterRun>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<SmsSourceMetadataEvent>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<SmsProcessingOperation>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<SmsProcessingAnalysis>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<SmsSelectorAttempt>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<SmsProcessingTraceEvent>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<SmsReconstructedResult>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<SmsPersistenceDecision>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<SmsReviewCase>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<SmsUserFeedbackEvent>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<SmsTransactionRevision>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<SmsAccountAlias>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<SmsLegacyTransactionSnapshot>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<SmsTraceImportReceipt>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<SmsContractReleaseState>()).isEmpty)
    }

    @MainActor
    func testPreBaselineUnversionedStorePreservesEvidenceWhetherOpenedOrRejected() throws {
        let directoryURL = FileManager.default.temporaryDirectory.appending(
            path: "PocketFinancerPreBaseline-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let storeURL = directoryURL.appending(path: "PocketFinancer.store")
        var retainedForProcessLifetime = false
        defer {
            if !retainedForProcessLifetime {
                try? FileManager.default.removeItem(at: directoryURL)
            }
        }
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let legacySchema = Schema([InboxAlert.self, PocketFinancer.Transaction.self, Account.self])
        let expectedID = UUID()

        try autoreleasepool {
            let configuration = ModelConfiguration(
                "PocketFinancerPreBaselineWriter",
                schema: legacySchema,
                url: storeURL,
                allowsSave: true,
                cloudKitDatabase: .none
            )
            let container = try ModelContainer(for: legacySchema, configurations: configuration)
            let context = container.mainContext
            context.insert(
                InboxAlert(
                    id: expectedID,
                    sourceIdentity: "synthetic-pre-baseline-source",
                    contentDigest: "synthetic-pre-baseline-digest",
                    origin: .manual,
                    sourceApplication: "Messages",
                    sender: "SYNTHETIC-SENDER",
                    rawBody: TestFixtures.validBody,
                    receivedAt: TestFixtures.receivedAt
                )
            )
            try context.save()
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: storeURL.path))
        do {
            let database = try AppDatabase(storeURL: storeURL)
            Self.retainedCompatibleStores.append((database, directoryURL))
            retainedForProcessLifetime = true
            let alerts = try database.container.mainContext.fetch(FetchDescriptor<InboxAlert>())
            XCTAssertEqual(alerts.count, 1)
            XCTAssertEqual(alerts.first?.id, expectedID)
            XCTAssertEqual(alerts.first?.rawBody, TestFixtures.validBody)
        } catch {
            guard let failure = error as? AppDatabaseStartupFailure else {
                return XCTFail("Expected a sanitized AppDatabaseStartupFailure")
            }
            XCTAssertEqual(failure.kind, .unrecognizedStoreModel)

            try autoreleasepool {
                let configuration = ModelConfiguration(
                    "PocketFinancerPreBaselineReader",
                    schema: legacySchema,
                    url: storeURL,
                    allowsSave: true,
                    cloudKitDatabase: .none
                )
                let container = try ModelContainer(for: legacySchema, configurations: configuration)
                let alerts = try container.mainContext.fetch(FetchDescriptor<InboxAlert>())

                XCTAssertEqual(alerts.count, 1)
                XCTAssertEqual(alerts.first?.id, expectedID)
                XCTAssertEqual(alerts.first?.rawBody, TestFixtures.validBody)
            }
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: storeURL.path))
    }
}
