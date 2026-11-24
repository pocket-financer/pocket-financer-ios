import SwiftData
import XCTest

@testable import PocketFinancer

private struct FixedExtractor: FoundationSmsExtracting {
    let rawOutput: String

    func extract(requestJSON: String) async throws -> DirectSelectorResponse {
        DirectSelectorResponse(
            rawOutput: rawOutput,
            runtimeProfileJSON: SmsFlatExtractionProjector.runtimeProfileJSON,
            requestJSON: requestJSON,
            completion: "complete"
        )
    }
}

@MainActor
final class NativeSmsProcessingTests: XCTestCase {
    func testContractAssetsVerifyManifestPromptsSchemasAndProfiles() throws {
        let bundle = try SmsContractAssets.verify()

        XCTAssertEqual(bundle.releaseID, "pocketfinancer.sms-pipeline/1")
        XCTAssertEqual(bundle.duplicateWindowMilliseconds, 300_000)
        XCTAssertEqual(bundle.artifactsByPath.count, 19)
        let prompt = try SmsContractAssets.extractorPrompt()
        XCTAssertTrue(prompt.contains("pocketfinancer.apple-fm-extractor-prompt/1"))
        let flatSchema = try SmsContractAssets.appleFlatSchema()
        let required = try XCTUnwrap(flatSchema["required"] as? [String])
        XCTAssertEqual(required.count, 18)
        let codes = try SmsContractAssets.currentISO4217CurrencyCodes()
        XCTAssertTrue(codes.contains("INR"))
        XCTAssertTrue(codes.contains("USD"))
    }

    func testOperationConfigurationUsesAutomaticRolloutAndFlatGuidedTransport() throws {
        let binding = try SmsContractAssets.verify()
        let configuration = try SmsOperationConfiguration(
            operationID: UUID(),
            parentOperationID: nil,
            sourceID: UUID(),
            trigger: "diagnostic",
            primaryCurrency: "INR",
            enabledProfiles: ["core-en", "india"],
            receivedAt: TestFixtures.receivedAt,
            admissionAt: TestFixtures.receivedAt,
            timezoneID: "UTC",
            binding: binding,
            extractorEligible: true,
            createdAt: TestFixtures.receivedAt
        )
        let payload = try configuration.payloadJSON()
        let hash = CanonicalJSON.sha256(payload)
        let document = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data((try configuration.documentJSON(configHash: hash)).utf8)
            ) as? [String: Any]
        )
        let extractor = try XCTUnwrap(document["extractor"] as? [String: Any])
        let policy = try XCTUnwrap(document["persistence_policy"] as? [String: Any])
        XCTAssertEqual(document["contract"] as? String, "pocketfinancer.sms-pipeline/1")
        XCTAssertTrue(document["parent_operation_id"] is NSNull)
        XCTAssertTrue(extractor["ineligibility_reason"] is NSNull)
        XCTAssertEqual(extractor["model_identity_kind"] as? String, "system_managed_runtime")
        XCTAssertTrue(extractor["model_file_sha256"] is NSNull)
        XCTAssertEqual(extractor["wire_transport"] as? String, "apple_fm_guided_flat")
        XCTAssertEqual(extractor["grammar_enabled"] as? Bool, false)
        XCTAssertTrue(extractor["grammar_sha256"] is NSNull)
        XCTAssertEqual(policy["rollout_mode"] as? String, "automatic")
        XCTAssertEqual(document["config_hash"] as? String, hash)
    }

    func testPrimaryCurrencyRequiresExplicitConfirmation() {
        let defaults = UserDefaults.standard
        let previousCode = defaults.object(forKey: PrimaryCurrencySettings.key)
        let previousConfirmed = defaults.object(forKey: PrimaryCurrencySettings.confirmationKey)
        defer {
            if let previousCode {
                defaults.set(previousCode, forKey: PrimaryCurrencySettings.key)
            } else {
                defaults.removeObject(forKey: PrimaryCurrencySettings.key)
            }
            if let previousConfirmed {
                defaults.set(previousConfirmed, forKey: PrimaryCurrencySettings.confirmationKey)
            } else {
                defaults.removeObject(forKey: PrimaryCurrencySettings.confirmationKey)
            }
        }
        defaults.removeObject(forKey: PrimaryCurrencySettings.key)
        defaults.removeObject(forKey: PrimaryCurrencySettings.confirmationKey)

        XCTAssertNil(PrimaryCurrencySettings.confirmedCode)
        PrimaryCurrencySettings.set("INR")
        XCTAssertNil(PrimaryCurrencySettings.confirmedCode)
        PrimaryCurrencySettings.confirm("USD")
        XCTAssertEqual(PrimaryCurrencySettings.confirmedCode, "USD")
    }

    func testAnalyzerUsesExactMinorUnitsAndBlocksExpectedRefund() async throws {
        let database = try AppDatabase(inMemory: true)
        let context = database.container.mainContext
        let alert = makeAlert(body: "Refund of INR 1,234.50 is expected tomorrow")
        context.insert(alert)
        try context.save()
        let snapshot = try makeSnapshot(context: context, alert: alert)

        let analysis = try StructuralSmsAnalyzer().analyze(
            source: alert.rawBody,
            operation: snapshot
        )

        XCTAssertEqual(
            analysis.candidates.first(where: { $0.kind == .amount })?.value["minor_units"],
            "123450"
        )
        XCTAssertTrue(analysis.reasonCodes.contains("expected_refund_not_posted"))
        XCTAssertEqual(analysis.completedEventCount, 0)
    }

    func testCoordinatorAutoSavesPostedExtractionWithResolvedAccount() async throws {
        let database = try AppDatabase(inMemory: true)
        let context = database.container.mainContext
        let account = Account(
            name: "HDFC Savings",
            bank: "HDFC Bank",
            kind: .account,
            suffix: "1234",
            now: TestFixtures.receivedAt
        )
        context.insert(account)
        let alert = makeAlert(body: "INR 10.00 was paid from account **1234 at CAFE")
        context.insert(alert)
        try context.save()
        let snapshot = try makeSnapshot(context: context, alert: alert)
        let raw = try TestFixtures.strictPostedOutput(
            for: alert.rawBody,
            amountText: "INR 10.00",
            amountValue: "10.00",
            direction: "debit",
            directionText: "paid",
            accountReference: "**1234",
            accountText: "**1234",
            counterpartyText: "CAFE"
        )
        let store = SmsProcessingStore(modelContainer: database.container)
        let coordinator = SmsProcessingCoordinator(
            store: store,
            extractor: FixedExtractor(rawOutput: raw),
            accountResolver: { _ in .unique(accountID: account.id) }
        )

        let outcome = await coordinator.process(
            source: AdmittedMessageRef(
                sourceID: alert.id,
                admissionReceiptID: alert.id,
                sourceDigest: CanonicalJSON.sha256(alert.rawBody)
            ),
            operation: snapshot
        )

        guard case .persisted(_, let transactionIDs, let alreadyCommitted) = outcome else {
            return XCTFail("Expected automatic persistence, got \(outcome)")
        }
        XCTAssertEqual(transactionIDs.count, 1)
        XCTAssertFalse(alreadyCommitted)

        let replayed = await coordinator.process(
            source: AdmittedMessageRef(
                sourceID: alert.id,
                admissionReceiptID: alert.id,
                sourceDigest: CanonicalJSON.sha256(alert.rawBody)
            ),
            operation: snapshot
        )
        XCTAssertEqual(
            replayed,
            .persisted(
                operationID: snapshot.operationID,
                transactionIDs: transactionIDs,
                alreadyCommitted: true
            )
        )

        let verification = ModelContext(database.container)
        let transactions = try verification.fetch(FetchDescriptor<Transaction>())
        XCTAssertEqual(transactions.count, 1)
        XCTAssertEqual(transactions.first?.id, transactionIDs.first)
        XCTAssertEqual(transactions.first?.accountID, account.id)
        XCTAssertEqual(transactions.first?.amountMinorUnits, 1_000)
        XCTAssertEqual(transactions.first?.parserName, "pocketfinancer.sms-pipeline/1")
        XCTAssertEqual(try verification.fetch(FetchDescriptor<SmsReviewCase>()).count, 0)
        let decision = try XCTUnwrap(
            verification.fetch(FetchDescriptor<SmsPersistenceDecision>()).first
        )
        XCTAssertEqual(decision.resultRawValue, "eligible")
        XCTAssertEqual(decision.primaryReason, "persistence_all_gates_passed")
        XCTAssertEqual(decision.rolloutMode, "automatic")
    }

    func testCoordinatorRoutesFiveMinuteDuplicateToReview() async throws {
        let database = try AppDatabase(inMemory: true)
        let context = database.container.mainContext
        let account = Account(
            name: "Card 1234",
            bank: "HDFC Bank",
            kind: .card,
            suffix: "1234",
            now: TestFixtures.receivedAt
        )
        context.insert(account)
        let body = "INR 500.00 paid from account **1234 at Demo Store."
        let first = makeAlert(body: body, receivedAt: TestFixtures.receivedAt)
        let withinWindow = makeAlert(
            body: body,
            receivedAt: TestFixtures.receivedAt.addingTimeInterval(240)
        )
        let outsideWindow = makeAlert(
            body: body,
            receivedAt: TestFixtures.receivedAt.addingTimeInterval(301)
        )
        context.insert(first)
        context.insert(withinWindow)
        context.insert(outsideWindow)
        try context.save()
        let raw = try TestFixtures.strictPostedOutput(
            for: body,
            amountText: "INR 500.00",
            amountValue: "500.00",
            direction: "debit",
            directionText: "paid",
            accountReference: "**1234",
            accountText: "**1234",
            counterpartyText: "Demo Store"
        )
        let store = SmsProcessingStore(modelContainer: database.container)
        let coordinator = SmsProcessingCoordinator(
            store: store,
            extractor: FixedExtractor(rawOutput: raw),
            accountResolver: { _ in .unique(accountID: account.id) }
        )

        let firstSnapshot = try makeSnapshot(context: context, alert: first)
        let firstOutcome = await coordinator.process(
            source: AdmittedMessageRef(
                sourceID: first.id,
                admissionReceiptID: first.id,
                sourceDigest: CanonicalJSON.sha256(body)
            ),
            operation: firstSnapshot
        )
        guard case .persisted = firstOutcome else {
            return XCTFail("Expected first transaction to persist automatically")
        }

        let duplicateSnapshot = try makeSnapshot(context: context, alert: withinWindow)
        let duplicateOutcome = await coordinator.process(
            source: AdmittedMessageRef(
                sourceID: withinWindow.id,
                admissionReceiptID: withinWindow.id,
                sourceDigest: CanonicalJSON.sha256(body)
            ),
            operation: duplicateSnapshot
        )
        guard case .retainedForReview(_, _, let reasons) = duplicateOutcome else {
            return XCTFail("Expected 5-minute duplicate to retain for review")
        }
        XCTAssertTrue(reasons.contains("duplicate_possible"))

        let laterSnapshot = try makeSnapshot(context: context, alert: outsideWindow)
        let laterOutcome = await coordinator.process(
            source: AdmittedMessageRef(
                sourceID: outsideWindow.id,
                admissionReceiptID: outsideWindow.id,
                sourceDigest: CanonicalJSON.sha256(body)
            ),
            operation: laterSnapshot
        )
        guard case .persisted = laterOutcome else {
            return XCTFail("Expected alert outside 5-minute window to auto-save")
        }
    }

    func testCoordinatorCreatesBodyFreeTombstonesForPrefilterAndExtractorNone() async throws {
        let database = try AppDatabase(inMemory: true)
        let context = database.container.mainContext
        let otpAlert = makeAlert(body: "Use 482910 as your OTP to log in.")
        let balanceAlert = makeAlert(body: "Your HDFC card balance is INR 10,000.00.")
        context.insert(otpAlert)
        context.insert(balanceAlert)
        try context.save()

        let store = SmsProcessingStore(modelContainer: database.container)
        let coordinator = SmsProcessingCoordinator(
            store: store,
            extractor: FixedExtractor(rawOutput: #"{"decision":"none"}"#),
            accountResolver: { _ in .unresolved }
        )

        let otpSnapshot = try makeSnapshot(context: context, alert: otpAlert)
        let otpOutcome = await coordinator.process(
            source: AdmittedMessageRef(
                sourceID: otpAlert.id,
                admissionReceiptID: otpAlert.id,
                sourceDigest: CanonicalJSON.sha256(otpAlert.rawBody)
            ),
            operation: otpSnapshot
        )
        XCTAssertEqual(
            otpOutcome,
            .terminallyDiscarded(
                operationID: otpSnapshot.operationID,
                reason: "prefilter_otp_verification"
            )
        )

        let balanceSnapshot = try makeSnapshot(context: context, alert: balanceAlert)
        let balanceOutcome = await coordinator.process(
            source: AdmittedMessageRef(
                sourceID: balanceAlert.id,
                admissionReceiptID: balanceAlert.id,
                sourceDigest: CanonicalJSON.sha256(balanceAlert.rawBody)
            ),
            operation: balanceSnapshot
        )
        XCTAssertEqual(
            balanceOutcome,
            .terminallyDiscarded(
                operationID: balanceSnapshot.operationID,
                reason: "extractor_none"
            )
        )

        let verification = ModelContext(database.container)
        let alerts = try verification.fetch(FetchDescriptor<InboxAlert>())
        XCTAssertTrue(alerts.allSatisfy { $0.rawBody.isEmpty && $0.status == .rejected })
        XCTAssertEqual(
            alerts.first { $0.id == otpAlert.id }?.rejectionCode,
            "tombstoned_excluded"
        )
        XCTAssertEqual(
            alerts.first { $0.id == balanceAlert.id }?.rejectionCode,
            "tombstoned_none"
        )
        let operations = try verification.fetch(FetchDescriptor<SmsProcessingOperation>())
        XCTAssertEqual(
            operations.first { $0.id == otpSnapshot.operationID }?.retentionState,
            "tombstoned_excluded"
        )
        XCTAssertEqual(
            operations.first { $0.id == balanceSnapshot.operationID }?.retentionState,
            "tombstoned_none"
        )
        let attempts = try verification.fetch(FetchDescriptor<SmsSelectorAttempt>())
        XCTAssertEqual(attempts.count, 1)
        XCTAssertEqual(attempts.first?.requestJSON, "{}")
        let analyses = try verification.fetch(FetchDescriptor<SmsProcessingAnalysis>())
        XCTAssertEqual(analyses.count, 1)
        XCTAssertEqual(analyses.first?.canonicalJSON, "{}")
    }

    @MainActor
    private func makeSnapshot(context: ModelContext, alert: InboxAlert) throws -> SmsOperationSnapshot {
        try SmsOperationSnapshotFactory(context: context).create(
            sourceAlertID: alert.id,
            trigger: "test",
            primaryCurrency: "INR",
            enabledProfiles: ["core-en", "india"],
            extractorEligibilityOverride: true,
            now: TestFixtures.receivedAt
        )
    }

    @MainActor
    private func makeAlert(body: String, receivedAt: Date = TestFixtures.receivedAt) -> InboxAlert {
        InboxAlert(
            sourceIdentity: UUID().uuidString,
            contentDigest: CanonicalJSON.sha256(body),
            origin: .manual,
            sourceApplication: "Tests",
            sender: "SYNTH",
            rawBody: body,
            receivedAt: receivedAt
        )
    }
}
