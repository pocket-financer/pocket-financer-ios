import SwiftData
import XCTest

@testable import PocketFinancer

@MainActor
final class SmsProcessingJSONTests: XCTestCase {
    func testSnapshotFactoryAndAutomaticRolloutConfigurationVerifyCleanly() throws {
        let database = try AppDatabase(inMemory: true)
        let context = database.container.mainContext
        let alert = InboxAlert(
            sourceIdentity: "json-test-\(UUID().uuidString)",
            contentDigest: CanonicalJSON.sha256(TestFixtures.validBody),
            origin: .manual,
            sourceApplication: "Test",
            sender: "AX-HDFCBK",
            rawBody: TestFixtures.validBody,
            receivedAt: TestFixtures.receivedAt
        )
        context.insert(alert)
        try context.save()

        let snapshot = try SmsOperationSnapshotFactory(context: context).create(
            sourceAlertID: alert.id,
            trigger: "manual",
            primaryCurrency: "INR",
            enabledProfiles: ["core-en", "india"],
            extractorEligibilityOverride: true
        )
        XCTAssertTrue(SmsProcessingJSON.configurationMatches(snapshot))
        XCTAssertEqual(snapshot.configuration.contract, "pocketfinancer.sms-pipeline/1")
        XCTAssertEqual(snapshot.configuration.extractor.wireTransport, "apple_fm_guided_flat")
        XCTAssertFalse(snapshot.configuration.extractor.grammarEnabled)
        XCTAssertNil(snapshot.configuration.extractor.grammarSHA256)
        XCTAssertEqual(snapshot.configuration.persistencePolicy.rolloutMode, "automatic")

        XCTAssertFalse(
            SmsProcessingJSON.configurationMatches(
                configurationJSON: snapshot.configurationJSON.replacingOccurrences(
                    of: "automatic",
                    with: "review_only"
                ),
                configurationHash: snapshot.configurationHash
            )
        )
    }

    func testGateEvaluatesAutomaticEligibilityAndBlocksOnDuplicatesOrMissingAccount() {
        let eligible = SmsProcessingJSON.gate(
            posted: true,
            accountReason: nil,
            duplicateStatus: "clear",
            rolloutMode: "automatic"
        )
        XCTAssertEqual(eligible["result"] as? String, "eligible")
        XCTAssertEqual(eligible["primary_reason"] as? String, "persistence_all_gates_passed")

        let duplicate = SmsProcessingJSON.gate(
            posted: true,
            accountReason: nil,
            duplicateStatus: "possible_duplicate",
            rolloutMode: "automatic"
        )
        XCTAssertEqual(duplicate["result"] as? String, "review_required")
        XCTAssertEqual(duplicate["primary_reason"] as? String, "duplicate_possible")

        let unresolved = SmsProcessingJSON.gate(
            posted: true,
            accountReason: "account_resolution_unresolved",
            duplicateStatus: "clear",
            rolloutMode: "automatic"
        )
        XCTAssertEqual(unresolved["result"] as? String, "review_required")
        XCTAssertEqual(unresolved["primary_reason"] as? String, "account_resolution_unresolved")
    }
}
