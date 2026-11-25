import SwiftData
import XCTest

@testable import PocketFinancer

final class PocketFinancerSchemaMigrationTests: XCTestCase {
    /// Production retains its shared container for the app process lifetime. Mirror that
    /// lifetime here because SwiftData can still be delivering a post-migration Core Data
    /// notification when `ModelContainer` returns. Releasing the migrated container inside
    /// an `autoreleasepool` races that notification on the iOS 26 simulator and aborts in
    /// `ModelContainer` teardown after every migration assertion has already passed.
    @MainActor private static var retainedMigratedStores: [(AppDatabase, URL)] = []

    @MainActor
    func testLightweightMigrationFromV1PreservesExistingModelsAndAddsExtractionRuns() throws {
        let directoryURL = FileManager.default.temporaryDirectory.appending(
            path: "PocketFinancerMigration-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let storeURL = directoryURL.appending(path: "PocketFinancer.store")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        var alertID: UUID?
        try autoreleasepool {
            let schema = Schema(versionedSchema: PocketFinancerSchemaV1.self)
            let configuration = ModelConfiguration(
                "PocketFinancerV1MigrationTest",
                schema: schema,
                url: storeURL,
                allowsSave: true,
                cloudKitDatabase: .none
            )
            let container = try ModelContainer(for: schema, configurations: configuration)
            let context = container.mainContext
            let alert = InboxAlert(
                sourceIdentity: "migration-source",
                contentDigest: "migration-digest",
                origin: .manual,
                sourceApplication: "Messages",
                sender: "legacy-sender",
                rawBody: TestFixtures.validBody,
                receivedAt: TestFixtures.receivedAt
            )
            alertID = alert.id
            context.insert(alert)
            try context.save()
        }

        try autoreleasepool {
            let migratedDatabase = try AppDatabase(storeURL: storeURL)
            Self.retainedMigratedStores.append((migratedDatabase, directoryURL))
            let context = migratedDatabase.container.mainContext
            let alerts = try context.fetch(FetchDescriptor<InboxAlert>())

            XCTAssertEqual(alerts.count, 1)
            XCTAssertEqual(alerts.first?.id, alertID)
            XCTAssertEqual(alerts.first?.rawBody, TestFixtures.validBody)
            XCTAssertTrue(try context.fetch(FetchDescriptor<Transaction>()).isEmpty)
            XCTAssertTrue(try context.fetch(FetchDescriptor<Account>()).isEmpty)
            XCTAssertTrue(try context.fetch(FetchDescriptor<ExtractionRun>()).isEmpty)
            XCTAssertTrue(try context.fetch(FetchDescriptor<StructuredGenerationSnapshot>()).isEmpty)
            XCTAssertTrue(try context.fetch(FetchDescriptor<DeterministicFilterRun>()).isEmpty)
        }
    }

    @MainActor
    func testLightweightMigrationFromV2PreservesExtractionRunsAndAddsStructuredSnapshots() throws {
        let directoryURL = FileManager.default.temporaryDirectory.appending(
            path: "PocketFinancerMigration-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let storeURL = directoryURL.appending(path: "PocketFinancer.store")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        var alertID: UUID?
        var extractionRunID: UUID?
        try autoreleasepool {
            let schema = Schema(versionedSchema: PocketFinancerSchemaV2.self)
            let configuration = ModelConfiguration(
                "PocketFinancerV2MigrationTest",
                schema: schema,
                url: storeURL,
                allowsSave: true,
                cloudKitDatabase: .none
            )
            let container = try ModelContainer(for: schema, configurations: configuration)
            let context = container.mainContext
            let alert = InboxAlert(
                sourceIdentity: "migration-v2-source",
                contentDigest: "migration-v2-digest",
                origin: .manual,
                sourceApplication: "Messages",
                sender: "legacy-v2-sender",
                rawBody: TestFixtures.validBody,
                receivedAt: TestFixtures.receivedAt
            )
            let extractionRun = ExtractionRun(
                alertID: alert.id,
                attemptIndex: 1,
                startedAt: TestFixtures.receivedAt,
                parserName: "Legacy V2 Parser",
                contractVersion: "legacy-contract.v2",
                profileVersion: "2",
                localeIdentifier: "en-US",
                localeWasSupported: true,
                supportedLanguageIdentifiers: ["en"],
                exactInstructions: "Legacy instructions",
                exactRequest: "Legacy request"
            )
            alertID = alert.id
            extractionRunID = extractionRun.id
            context.insert(alert)
            context.insert(extractionRun)
            try context.save()
        }

        try autoreleasepool {
            let migratedDatabase = try AppDatabase(storeURL: storeURL)
            Self.retainedMigratedStores.append((migratedDatabase, directoryURL))
            let context = migratedDatabase.container.mainContext
            let alerts = try context.fetch(FetchDescriptor<InboxAlert>())
            let extractionRuns = try context.fetch(FetchDescriptor<ExtractionRun>())

            XCTAssertEqual(alerts.count, 1)
            XCTAssertEqual(alerts.first?.id, alertID)
            XCTAssertEqual(extractionRuns.count, 1)
            XCTAssertEqual(extractionRuns.first?.id, extractionRunID)
            XCTAssertEqual(extractionRuns.first?.parserName, "Legacy V2 Parser")
            XCTAssertEqual(extractionRuns.first?.exactRequest, "Legacy request")
            XCTAssertTrue(try context.fetch(FetchDescriptor<StructuredGenerationSnapshot>()).isEmpty)
            XCTAssertTrue(try context.fetch(FetchDescriptor<DeterministicFilterRun>()).isEmpty)
        }
    }

    @MainActor
    func testLightweightMigrationFromV3PreservesStructuredSnapshotsAndAddsFilterRuns() throws {
        let directoryURL = FileManager.default.temporaryDirectory.appending(
            path: "PocketFinancerMigration-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let storeURL = directoryURL.appending(path: "PocketFinancer.store")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        var alertID: UUID?
        var extractionRunID: UUID?
        var snapshotID: UUID?
        try autoreleasepool {
            let schema = Schema(versionedSchema: PocketFinancerSchemaV3.self)
            let configuration = ModelConfiguration(
                "PocketFinancerV3MigrationTest",
                schema: schema,
                url: storeURL,
                allowsSave: true,
                cloudKitDatabase: .none
            )
            let container = try ModelContainer(for: schema, configurations: configuration)
            let context = container.mainContext
            let alert = InboxAlert(
                sourceIdentity: "migration-v3-source",
                contentDigest: "migration-v3-digest",
                origin: .manual,
                sourceApplication: "Messages",
                sender: "legacy-v3-sender",
                rawBody: TestFixtures.validBody,
                receivedAt: TestFixtures.receivedAt
            )
            let extractionRun = ExtractionRun(
                alertID: alert.id,
                attemptIndex: 1,
                startedAt: TestFixtures.receivedAt,
                parserName: "Legacy V3 Parser",
                contractVersion: "legacy-contract.v3",
                profileVersion: "3",
                localeIdentifier: "en-US",
                localeWasSupported: true,
                supportedLanguageIdentifiers: ["en"],
                exactInstructions: "Legacy instructions",
                exactRequest: "Legacy request"
            )
            let snapshot = StructuredGenerationSnapshot(
                extractionRunID: extractionRun.id,
                sequenceIndex: 0,
                capturedAt: TestFixtures.receivedAt,
                rawContentJSON: #"{"amount":"125.00"}"#,
                isComplete: true
            )
            alertID = alert.id
            extractionRunID = extractionRun.id
            snapshotID = snapshot.id
            context.insert(alert)
            context.insert(extractionRun)
            context.insert(snapshot)
            try context.save()
        }

        try autoreleasepool {
            let migratedDatabase = try AppDatabase(storeURL: storeURL)
            Self.retainedMigratedStores.append((migratedDatabase, directoryURL))
            let context = migratedDatabase.container.mainContext
            let alerts = try context.fetch(FetchDescriptor<InboxAlert>())
            let extractionRuns = try context.fetch(FetchDescriptor<ExtractionRun>())
            let snapshots = try context.fetch(FetchDescriptor<StructuredGenerationSnapshot>())

            XCTAssertEqual(alerts.first?.id, alertID)
            XCTAssertEqual(extractionRuns.first?.id, extractionRunID)
            XCTAssertEqual(snapshots.first?.id, snapshotID)
            XCTAssertEqual(snapshots.first?.rawContentJSON, #"{"amount":"125.00"}"#)
            XCTAssertTrue(try context.fetch(FetchDescriptor<DeterministicFilterRun>()).isEmpty)
        }
    }

    @MainActor
    func testV6ToV7PreservesDurableAttemptAndRecoversExpiredOperation() async throws {
        let directoryURL = FileManager.default.temporaryDirectory.appending(
            path: "PocketFinancerMigration-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let storeURL = directoryURL.appending(path: "PocketFinancer.store")
        try FileManager.default.createDirectory(
            at: directoryURL, withIntermediateDirectories: true
        )
        let operationID = UUID()
        let alertID = UUID()
        try autoreleasepool {
            let schema = Schema(versionedSchema: PocketFinancerSchemaV6.self)
            let configuration = ModelConfiguration(
                "PocketFinancerV6MigrationTest",
                schema: schema,
                url: storeURL,
                allowsSave: true,
                cloudKitDatabase: .none
            )
            let container = try ModelContainer(for: schema, configurations: configuration)
            let context = container.mainContext
            let alert = InboxAlert(
                id: alertID,
                sourceIdentity: "migration-v6-source",
                contentDigest: "migration-v6-digest",
                origin: .manual,
                sourceApplication: "Messages",
                sender: "SYNTH-BANK",
                rawBody: TestFixtures.validBody,
                receivedAt: TestFixtures.receivedAt
            )
            let operation = SmsProcessingOperation(
                id: operationID,
                sourceAlertID: alertID,
                trigger: "manual",
                configurationJSON: #"{"contract":"pocketfinancer.processing-config/2"}"#,
                configurationHash: String(repeating: "a", count: 64),
                contractReleaseID: "native-integration-v2",
                state: .claimed,
                createdAt: TestFixtures.receivedAt.addingTimeInterval(-600)
            )
            operation.ownerToken = UUID()
            operation.claimExpiresAt = TestFixtures.receivedAt.addingTimeInterval(-300)
            operation.updatedAt = TestFixtures.receivedAt.addingTimeInterval(-600)
            let attempt = SmsSelectorAttempt(
                operationID: operationID,
                attemptIndex: 0,
                runtimeProfileJSON: #"{"generation_mode":"DIRECT_NON_THINKING"}"#,
                requestJSON: #"{"contract":"pocketfinancer.sms-extractor-input/1"}"#,
                startedAt: TestFixtures.receivedAt.addingTimeInterval(-500)
            )
            attempt.completionRawValue = "interrupted"
            context.insert(alert)
            context.insert(operation)
            context.insert(attempt)
            try context.save()
        }

        let migratedDatabase = try AppDatabase(storeURL: storeURL)
        Self.retainedMigratedStores.append((migratedDatabase, directoryURL))
        let store = SmsProcessingStore(modelContainer: migratedDatabase.container)
        let recovered = try await store.recoverExpiredOperations(
            now: TestFixtures.receivedAt
        )
        XCTAssertEqual(recovered.count, 1)
        let context = migratedDatabase.container.mainContext
        let targetOperationID = operationID
        let operations = try context.fetch(
            FetchDescriptor<SmsProcessingOperation>(
                predicate: #Predicate { $0.id == targetOperationID }
            ))
        XCTAssertEqual(operations.first?.state, .retainedReview)
        let attempts = try context.fetch(
            FetchDescriptor<SmsSelectorAttempt>(
                predicate: #Predicate { $0.operationID == targetOperationID }
            ))
        XCTAssertEqual(attempts.first?.completionRawValue, "interrupted")
        let reviews = try context.fetch(FetchDescriptor<SmsReviewCase>())
        XCTAssertEqual(reviews.first?.currentOperationID, operationID)
        XCTAssertEqual(reviews.first?.reasonCodesRawValue, "operation_interrupted")
    }
}
