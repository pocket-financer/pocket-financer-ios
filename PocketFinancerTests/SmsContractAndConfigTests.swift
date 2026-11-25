import Foundation
import SwiftData
import XCTest

@testable import PocketFinancer

@MainActor
final class SmsContractAndConfigTests: XCTestCase {
    func testContractAssetsVerifyManifestPromptsSchemasProfilesAndRejectInvalidPaths() throws {
        let bundle = try SmsContractAssets.verify()

        XCTAssertEqual(bundle.releaseID, "pocketfinancer.sms-pipeline/1")
        XCTAssertEqual(bundle.duplicateWindowMilliseconds, 300_000)
        XCTAssertEqual(bundle.artifactsByPath.count, 19)
        XCTAssertEqual(SmsContractAssets.requiredIOSAssetPaths.count, 17)

        for path in SmsContractAssets.requiredIOSAssetPaths {
            XCTAssertEqual(try bundle.sha256(forRelativePath: path).count, 64, path)
        }

        let prompt = try SmsContractAssets.extractorPrompt()
        XCTAssertTrue(prompt.contains("pocketfinancer.apple-fm-extractor-prompt/1"))
        XCTAssertTrue(prompt.contains(#""posted""#))

        let flatSchema = try SmsContractAssets.appleFlatSchema()
        let required = try XCTUnwrap(flatSchema["required"] as? [String])
        XCTAssertEqual(required.count, 18)

        let codes = try SmsContractAssets.currentISO4217CurrencyCodes()
        XCTAssertTrue(codes.contains("INR"))
        XCTAssertTrue(codes.contains("USD"))
        XCTAssertTrue(codes.contains("EUR"))

        XCTAssertThrowsError(try bundle.sha256(forRelativePath: "profiles/does-not-exist.json")) { error in
            XCTAssertEqual(error as? SmsContractAssetError, .configurationIntegrityFailure)
        }
        let unsafePaths = [
            "",
            "/etc/passwd",
            "../release-manifest.json",
            "profiles\\currency.json",
            "profiles/./currency.json",
        ]
        for unsafePath in unsafePaths {
            XCTAssertThrowsError(try SmsContractAssets.loadData(forRelativePath: unsafePath)) { error in
                XCTAssertEqual(error as? SmsContractAssetError, .configurationIntegrityFailure)
            }
        }
    }

    func testSnapshotFactoryProducesVerifiableAutomaticFlatGuidedConfiguration() throws {
        let database = try AppDatabase(inMemory: true)
        let context = database.container.mainContext
        let alert = TestFixtures.makeAlert()
        context.insert(alert)
        try context.save()

        let snapshot = try SmsOperationSnapshotFactory(context: context).create(
            sourceAlertID: alert.id,
            trigger: "automatic_recovery",
            primaryCurrency: "INR",
            enabledProfiles: ["core-en", "india"],
            extractorEligibilityOverride: true,
            now: TestFixtures.receivedAt
        )

        XCTAssertTrue(SmsProcessingJSON.configurationMatches(snapshot))
        XCTAssertEqual(snapshot.configuration.contract, "pocketfinancer.sms-pipeline/1")
        XCTAssertEqual(snapshot.configuration.trigger, "background_recovery")
        XCTAssertEqual(snapshot.configuration.extractor.modelIdentityKind, "system_managed_runtime")
        XCTAssertNil(snapshot.configuration.extractor.modelFileSHA256)
        XCTAssertEqual(snapshot.configuration.extractor.wireTransport, "apple_fm_guided_flat")
        XCTAssertFalse(snapshot.configuration.extractor.grammarEnabled)
        XCTAssertNil(snapshot.configuration.extractor.grammarSHA256)
        XCTAssertEqual(snapshot.configuration.persistencePolicy.rolloutMode, "automatic")

        let document = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(snapshot.configurationJSON.utf8)) as? [String: Any]
        )
        let extractor = try XCTUnwrap(document["extractor"] as? [String: Any])
        XCTAssertTrue(document["parent_operation_id"] is NSNull)
        XCTAssertTrue(extractor["ineligibility_reason"] is NSNull)
        XCTAssertTrue(extractor["model_file_sha256"] is NSNull)
        XCTAssertTrue(extractor["grammar_sha256"] is NSNull)
        XCTAssertEqual(document["config_hash"] as? String, snapshot.configurationHash)

        XCTAssertFalse(
            SmsProcessingJSON.configurationMatches(
                configurationJSON: snapshot.configurationJSON.replacingOccurrences(
                    of: "automatic",
                    with: "review_only"
                ),
                configurationHash: snapshot.configurationHash
            )
        )
        XCTAssertFalse(
            SmsProcessingJSON.configurationMatches(
                configurationJSON: snapshot.configurationJSON,
                configurationHash: String(repeating: "0", count: 64)
            )
        )
    }

    func testSnapshotFactoryRejectsInvalidCurrencyProfilesOrMissingReferences() throws {
        let database = try AppDatabase(inMemory: true)
        let context = database.container.mainContext
        let alert = TestFixtures.makeAlert()
        context.insert(alert)
        try context.save()
        let factory = SmsOperationSnapshotFactory(context: context)

        XCTAssertThrowsError(
            try factory.create(
                sourceAlertID: alert.id,
                trigger: "manual",
                primaryCurrency: "ZZZ",
                enabledProfiles: ["core-en"]
            )
        ) { error in
            XCTAssertEqual(error as? SmsProcessingStoreError, .configurationMismatch)
        }
        XCTAssertThrowsError(
            try factory.create(
                sourceAlertID: alert.id,
                trigger: "manual",
                primaryCurrency: "INR",
                enabledProfiles: ["core-en", "core-en"]
            )
        ) { error in
            XCTAssertEqual(error as? SmsProcessingStoreError, .configurationMismatch)
        }
        XCTAssertThrowsError(
            try factory.create(
                sourceAlertID: alert.id,
                trigger: "manual",
                primaryCurrency: "INR",
                enabledProfiles: ["unknown-profile"]
            )
        ) { error in
            XCTAssertEqual(error as? SmsProcessingStoreError, .configurationMismatch)
        }
        XCTAssertThrowsError(
            try factory.create(
                sourceAlertID: UUID(),
                trigger: "manual",
                primaryCurrency: "INR",
                enabledProfiles: ["core-en"]
            )
        ) { error in
            XCTAssertEqual(error as? SmsProcessingStoreError, .sourceNotFound)
        }
        XCTAssertThrowsError(
            try factory.create(
                sourceAlertID: alert.id,
                parentOperationID: UUID(),
                trigger: "retry",
                primaryCurrency: "INR",
                enabledProfiles: ["core-en"]
            )
        ) { error in
            XCTAssertEqual(error as? SmsProcessingStoreError, .operationNotFound)
        }
    }

    func testProcessingJSONBuildsRequestsAccountsAndPersistenceGateDecisions() throws {
        let database = try AppDatabase(inMemory: true)
        let context = database.container.mainContext
        let alert = TestFixtures.makeAlert()
        context.insert(alert)
        try context.save()
        let snapshot = try TestFixtures.makeSnapshot(context: context, alert: alert)
        let analysis = try StructuralSmsAnalyzer().analyze(source: alert.rawBody, operation: snapshot)

        let requestJSON = try SmsProcessingJSON.request(
            source: alert.rawBody,
            sender: "AX-HDFC123",
            analysis: analysis,
            configuration: snapshot.configuration
        )
        let requestObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(requestJSON.utf8)) as? [String: Any]
        )
        XCTAssertEqual(requestObject["contract"] as? String, "pocketfinancer.sms-extractor-input/1")
        XCTAssertEqual(requestObject["output_contract"] as? String, "pocketfinancer.sms-extractor/1")
        XCTAssertEqual(requestObject["sender_family"] as? String, "hdfc#")

        let emptySenderRequest = try SmsProcessingJSON.request(
            source: alert.rawBody,
            sender: "   ",
            analysis: analysis,
            configuration: snapshot.configuration
        )
        let emptySenderObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(emptySenderRequest.utf8)) as? [String: Any]
        )
        XCTAssertEqual(emptySenderObject["sender_family"] as? String, "unknown")

        let accountID = UUID()
        let uniqueSuffix = SmsProcessingJSON.account(.unique(accountID: accountID), reference: "1234")
        XCTAssertEqual(uniqueSuffix["status"] as? String, "uniquely_resolved")
        XCTAssertEqual(uniqueSuffix["normalized_reference"] as? String, "suffix:1234")
        XCTAssertEqual(uniqueSuffix["matched_alias_hash"] as? String, CanonicalJSON.sha256("suffix:1234"))

        let uniqueVPA = SmsProcessingJSON.account(.unique(accountID: accountID), reference: "user@bank")
        XCTAssertEqual(uniqueVPA["normalized_reference"] as? String, "vpa:user@bank")
        XCTAssertEqual(uniqueVPA["matched_alias_hash"] as? String, CanonicalJSON.sha256("vpa:user@bank"))

        let ambiguous = SmsProcessingJSON.account(.ambiguous(accountIDs: [UUID(), UUID()]), reference: "1234")
        XCTAssertEqual(ambiguous["status"] as? String, "ambiguous")
        XCTAssertEqual(ambiguous["match_count"] as? Int, 2)
        XCTAssertEqual(SmsProcessingJSON.accountReasons(.ambiguous(accountIDs: [])), ["account_resolution_ambiguous"])

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

        let notPosted = SmsProcessingJSON.gate(
            posted: false,
            accountReason: nil,
            duplicateStatus: "clear",
            rolloutMode: "automatic"
        )
        XCTAssertEqual(notPosted["result"] as? String, "not_posted")
        XCTAssertEqual(notPosted["primary_reason"] as? String, "persistence_not_posted")

        let blockedByMode = SmsProcessingJSON.gate(
            posted: true,
            accountReason: nil,
            duplicateStatus: "clear",
            rolloutMode: "review_only"
        )
        XCTAssertEqual(blockedByMode["result"] as? String, "blocked_by_mode")
        XCTAssertEqual(blockedByMode["primary_reason"] as? String, "persistence_blocked_by_rollout_mode")

        let checksRaw = try SmsProcessingJSON.checksJSON(
            posted: true,
            accountReason: nil,
            duplicateStatus: "clear",
            rolloutMode: "automatic"
        )
        let checks = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(checksRaw.utf8)) as? [[String: Any]]
        )
        XCTAssertEqual(checks.count, 11)
        XCTAssertTrue(checks.allSatisfy { ($0["passed"] as? Bool) == true })
    }
}
