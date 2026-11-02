import SwiftData
import XCTest

@testable import PocketFinancer

final class PocketFinancerV5MigrationTests: XCTestCase {
    @MainActor private static var retainedStores: [(AppDatabase, URL)] = []

    @MainActor
    func testV4MigrationPreservesLedgerAndCreatesHonestLegacyHistory() async throws {
        let directoryURL = FileManager.default.temporaryDirectory.appending(
            path: "PocketFinancerV5Migration-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let storeURL = directoryURL.appending(path: "PocketFinancer.store")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let alertID = UUID()
        let transactionID = UUID()
        try autoreleasepool {
            let schema = Schema(versionedSchema: PocketFinancerSchemaV4.self)
            let configuration = ModelConfiguration(
                "PocketFinancerV4MigrationTest",
                schema: schema,
                url: storeURL,
                allowsSave: true,
                cloudKitDatabase: .none
            )
            let container = try ModelContainer(for: schema, configurations: configuration)
            let context = container.mainContext
            context.insert(
                InboxAlert(
                    id: alertID,
                    sourceIdentity: "v4-synthetic-source",
                    contentDigest: "v4-synthetic-digest",
                    origin: .manual,
                    sourceApplication: "Messages",
                    sender: "SYNTH",
                    rawBody: TestFixtures.validBody,
                    receivedAt: TestFixtures.receivedAt
                )
            )
            context.insert(
                Transaction(
                    id: transactionID,
                    amountMinorUnits: 50000,
                    currencyCode: "INR",
                    merchant: "SYNTH STORE",
                    occurredAt: TestFixtures.receivedAt,
                    direction: .debit,
                    accountID: nil,
                    accountLabel: nil,
                    isEdited: true,
                    parserName: "V4 parser",
                    reviewState: .confirmed,
                    sourceAlertID: alertID,
                    amountEvidenceText: "INR 500",
                    dateEvidenceText: nil
                )
            )
            try context.save()
        }

        let database = try AppDatabase(storeURL: storeURL)
        Self.retainedStores.append((database, directoryURL))
        try await database.prepareForProcessing()
        let context = ModelContext(database.container)
        let transactions = try context.fetch(FetchDescriptor<Transaction>())
        let snapshots = try context.fetch(FetchDescriptor<SmsLegacyTransactionSnapshot>())
        let revisions = try context.fetch(FetchDescriptor<SmsTransactionRevision>())

        XCTAssertEqual(transactions.map(\.id), [transactionID])
        XCTAssertEqual(transactions.first?.amountMinorUnits, 50000)
        XCTAssertEqual(snapshots.first?.transactionID, transactionID)
        XCTAssertFalse(snapshots.first?.originalEditHistoryKnown ?? true)
        XCTAssertEqual(revisions.first?.provenanceRawValue, "legacy_current_state_original_history_unknown")
    }

    @MainActor
    func testV5FeedbackMigratesToOptionalOperationAndTransactionReferences() throws {
        let directoryURL = FileManager.default.temporaryDirectory.appending(
            path: "PocketFinancerV6Migration-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let storeURL = directoryURL.appending(path: "PocketFinancer.store")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let actionID = UUID()
        let reviewCaseID = UUID()
        let operationID = UUID()

        try autoreleasepool {
            let schema = Schema(versionedSchema: PocketFinancerSchemaV5.self)
            let configuration = ModelConfiguration(
                "PocketFinancerV5MigrationTest",
                schema: schema,
                url: storeURL,
                allowsSave: true,
                cloudKitDatabase: .none
            )
            let container = try ModelContainer(for: schema, configurations: configuration)
            let context = container.mainContext
            context.insert(
                PocketFinancerSchemaV5.SmsUserFeedbackEvent(
                    actionID: actionID,
                    reviewCaseID: reviewCaseID,
                    operationID: operationID,
                    transactionRevisionID: nil,
                    expectedReviewRevision: 0,
                    resultingReviewRevision: 1,
                    action: "rejected",
                    actorClass: "user",
                    correctionsJSON: "[]",
                    retryConfiguration: nil,
                    previousEventHash: nil,
                    eventHash: "synthetic-v5-event-hash",
                    createdAt: TestFixtures.receivedAt
                )
            )
            try context.save()
        }

        let database = try AppDatabase(storeURL: storeURL)
        Self.retainedStores.append((database, directoryURL))
        let feedback = try database.container.mainContext.fetch(
            FetchDescriptor<SmsUserFeedbackEvent>()
        )

        XCTAssertEqual(feedback.first?.actionID, actionID)
        XCTAssertEqual(feedback.first?.reviewCaseID, reviewCaseID)
        XCTAssertEqual(feedback.first?.operationID, operationID)
        XCTAssertNil(feedback.first?.transactionID)
    }
}
